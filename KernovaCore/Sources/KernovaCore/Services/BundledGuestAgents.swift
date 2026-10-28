import Foundation
import KernovaAgentCore
import KernovaLogging
import KernovaWire
import Synchronization

/// One guest agent this copy of Kernova bundles: what it installs onto, the file that carries it, and how
/// the file is identified.
package struct BundledGuestAgentEntry: Sendable, Equatable {
    /// How an entry's file is identified.
    package enum Kind: Sendable, Equatable {
        /// An installer disk image the user runs inside the guest, identified by its agent's version: the
        /// macOS agent's DMG.
        case installerDisk(version: String)
        /// An update payload, identified by its SHA-256, which ``BundledGuestAgents/payloads(for:)``
        /// computes; `versionLabel` is the display version it installs.
        case payload(PayloadFormat, versionLabel: String)
    }

    /// The OS family it installs onto.
    package let os: OSFamily
    /// The architecture it installs onto.
    package let architecture: Architecture
    /// The install scope it serves.
    package let scope: InstallScope
    /// The file in the app bundle.
    package let fileURL: URL
    /// How the file is identified.
    package let kind: Kind

    package init(os: OSFamily, architecture: Architecture, scope: InstallScope, fileURL: URL, kind: Kind) {
        self.os = os
        self.architecture = architecture
        self.scope = scope
        self.fileURL = fileURL
        self.kind = kind
    }
}

/// The guest agents a host bundles, keyed by (OS family, architecture, install scope): the macOS agent's
/// installer DMG, which the "Package Guest Agent DMG" build phase writes, and the Linux `kernova-agent`,
/// which "Build Linux Guest Agent" writes, serving both the user and the system scope from one file. A file
/// the bundle lacks has no entry, so what it would deliver is not offered.
///
/// One of the ``AppBundleProducts``, which reads the app's.
package struct BundledGuestAgents: Sendable {
    /// Label every attachment of the macOS installer image carries, matching the volume name the "Package
    /// Guest Agent DMG" build phase gives it — so the name Kernova shows for the attachment is the name the
    /// guest shows for the mounted volume.
    package static let macOSDiskLabel = "Kernova Guest Agent"

    /// Every entry, in no particular order; at most one per key.
    package let entries: [BundledGuestAgentEntry]

    private let manifests: PayloadManifests

    package init(entries: [BundledGuestAgentEntry]) {
        self.entries = entries
        self.manifests = PayloadManifests()
    }

    /// The agents `bundle` carries; `versionLabel` is the display version of the payloads the bundle's own
    /// build labelled.
    init(bundle: Bundle, versionLabel: String) {
        var entries: [BundledGuestAgentEntry] = []
        if let dmg = bundle.url(forResource: "KernovaMacOSAgent", withExtension: "dmg"),
            let version = Self.macOSVersion(in: bundle)
        {
            entries.append(
                BundledGuestAgentEntry(
                    os: .macOS, architecture: .arm64, scope: .user, fileURL: dmg,
                    kind: .installerDisk(version: version)))
        }
        if let agent = bundle.url(
            forResource: "kernova-agent", withExtension: nil, subdirectory: "GuestAgents/linux-arm64")
        {
            for scope in [InstallScope.user, .system] {
                entries.append(
                    BundledGuestAgentEntry(
                        os: .linux, architecture: .arm64, scope: scope, fileURL: agent,
                        kind: .payload(.executable, versionLabel: versionLabel)))
            }
        } else {
            Self.logger.log(.fault, "GuestAgents/linux-arm64/kernova-agent missing from app bundle")
        }
        self.init(entries: entries)
    }

    /// The entry for `os`, `architecture` and `scope`, or nil when none is bundled.
    package func entry(
        _ os: OSFamily, _ architecture: Architecture, _ scope: InstallScope
    ) -> BundledGuestAgentEntry? {
        entries.first { $0.os == os && $0.architecture == architecture && $0.scope == scope }
    }

    /// The update payloads bundled for `os`, each with the manifest the host offers a peer it fits
    /// (`BundledPayload.offer(from:for:)`). Each file is hashed once per launch, off the main actor, on the
    /// first ask; entries sharing a file share its manifest. A file that cannot be read is logged and left
    /// out.
    package func payloads(for os: OSFamily) async -> [BundledPayload] {
        var payloads: [BundledPayload] = []
        for entry in entries where entry.os == os {
            guard case .payload(let format, let versionLabel) = entry.kind,
                let manifest = await manifests.manifest(of: entry.fileURL, format: format, versionLabel: versionLabel)
            else { continue }
            payloads.append(
                BundledPayload(
                    os: entry.os, architecture: entry.architecture, scope: entry.scope, manifest: manifest))
        }
        return payloads
    }

    // MARK: The macOS agent

    /// The macOS agent's entry, the one of user scope on arm64.
    private var macOS: BundledGuestAgentEntry? {
        entry(.macOS, .arm64, .user)
    }

    /// The version of the macOS guest agent embedded in this build of the host; `nil` when none is.
    package var macOSVersion: String? {
        guard case .installerDisk(let version) = macOS?.kind else { return nil }
        return version
    }

    /// The macOS agent's installer DMG, or `nil` when none is bundled.
    package var macOSInstallerDiskImageURL: URL? {
        macOS?.fileURL
    }

    /// Filesystem path of the macOS agent's installer DMG, if bundled.
    var macOSInstallerPath: String? {
        macOSInstallerDiskImageURL?.path(percentEncoded: false)
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "BundledGuestAgents")

    private static func macOSVersion(in bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: "KernovaMacOSAgentVersion", withExtension: "txt") else {
            logger.log(.fault, "KernovaMacOSAgentVersion.txt missing from app bundle")
            assertionFailure(
                "KernovaMacOSAgentVersion.txt missing — check 'Package Guest Agent DMG' build phase outputs")
            return nil
        }
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                logger.log(.fault, "KernovaMacOSAgentVersion.txt is empty")
                assertionFailure("KernovaMacOSAgentVersion.txt is empty")
                return nil
            }
            return trimmed
        } catch {
            logger.log(
                .fault,
                "Failed to read KernovaMacOSAgentVersion.txt: \(error.localizedDescription, privacy: .public)")
            assertionFailure("Failed to read KernovaMacOSAgentVersion.txt: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Each payload file's manifest, computed once per launch on the first ask. The code signature seals the
/// bundle's files, so a manifest stays true for the life of the process.
private final class PayloadManifests: Sendable {
    private let tasks = Mutex<[URL: Task<UpdateManifestValue?, Never>]>([:])

    func manifest(of url: URL, format: PayloadFormat, versionLabel: String) async -> UpdateManifestValue? {
        let task = tasks.withLock { tasks in
            if let task = tasks[url] { return task }
            let task = Task { () async -> UpdateManifestValue? in
                do {
                    let digest = try await FileDigest.digest(of: url, priority: .utility, progressHandler: nil)
                    return UpdateManifestValue(
                        payloadHash: digest.sha256, payloadSize: digest.byteCount, format: format,
                        versionLabel: versionLabel)
                } catch {
                    Self.logger.log(
                        .fault,
                        """
                        Cannot hash the bundled payload \(url.lastPathComponent, privacy: .public): \
                        \(error.localizedDescription, privacy: .public)
                        """)
                    return nil
                }
            }
            tasks[url] = task
            return task
        }
        return await task.value
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "BundledGuestAgents")
}
