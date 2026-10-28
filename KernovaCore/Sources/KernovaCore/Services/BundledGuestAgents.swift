import Foundation
import KernovaAgentCore
import KernovaCommandModel
import KernovaLogging
import KernovaWire
import Synchronization

/// What one bundled guest agent installs onto.
package struct BundledGuestAgentKey: Hashable, Sendable {
    /// The OS family.
    package let os: OSFamily
    /// The architecture.
    package let architecture: Architecture
    /// The install scope it serves.
    package let scope: InstallScope

    package init(_ os: OSFamily, _ architecture: Architecture, _ scope: InstallScope) {
        self.os = os
        self.architecture = architecture
        self.scope = scope
    }
}

/// One guest agent this copy of Kernova bundles: the file that carries it, and how the file is identified.
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

    /// The file in the app bundle.
    package let fileURL: URL
    /// How the file is identified.
    package let kind: Kind

    package init(fileURL: URL, kind: Kind) {
        self.fileURL = fileURL
        self.kind = kind
    }
}

/// The guest agents a host bundles, one per (OS family, architecture, install scope): the macOS agent's
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

    /// Where the bundle carries the Linux agent, under its Resources.
    static let linuxAgentPath = "GuestAgents/linux-arm64/kernova-agent"

    /// Every entry, by what it installs onto.
    package let entries: [BundledGuestAgentKey: BundledGuestAgentEntry]

    /// Where the Linux agent's installer disk is made.
    package let linuxDisk: GuestAgentDiskCache

    private let digests: FileDigests

    package init(entries: [BundledGuestAgentKey: BundledGuestAgentEntry], linuxDisk: GuestAgentDiskCache) {
        self.entries = entries
        self.linuxDisk = linuxDisk
        self.digests = FileDigests()
    }

    /// The agents `bundle` carries; `versionLabel` is the display version of the payloads the bundle's own
    /// build labelled. Every build bundles the Linux agent, so one missing is a packaging defect.
    init(bundle: Bundle, versionLabel: String) {
        let entries = Self.entries(in: bundle, versionLabel: versionLabel)
        if entries[BundledGuestAgentKey(.linux, .arm64, .user)] == nil {
            Self.logger.log(.fault, "\(Self.linuxAgentPath, privacy: .public) missing from app bundle")
            assertionFailure("\(Self.linuxAgentPath) missing — check the 'Build Linux Guest Agent' build phase")
        }
        self.init(entries: entries, linuxDisk: .production)
    }

    /// The entries for the files `bundle` carries.
    static func entries(in bundle: Bundle, versionLabel: String) -> [BundledGuestAgentKey: BundledGuestAgentEntry] {
        var entries: [BundledGuestAgentKey: BundledGuestAgentEntry] = [:]
        if let dmg = bundle.url(forResource: "KernovaMacOSAgent", withExtension: "dmg"),
            let version = macOSVersion(in: bundle)
        {
            entries[BundledGuestAgentKey(.macOS, .arm64, .user)] = BundledGuestAgentEntry(
                fileURL: dmg, kind: .installerDisk(version: version))
        }
        if let agent = bundle.url(
            forResource: "kernova-agent", withExtension: nil, subdirectory: "GuestAgents/linux-arm64")
        {
            for scope in [InstallScope.user, .system] {
                entries[BundledGuestAgentKey(.linux, .arm64, scope)] = BundledGuestAgentEntry(
                    fileURL: agent, kind: .payload(.executable, versionLabel: versionLabel))
            }
        }
        return entries
    }

    /// The entry for `os`, `architecture` and `scope`, or nil when none is bundled.
    package func entry(
        _ os: OSFamily, _ architecture: Architecture, _ scope: InstallScope
    ) -> BundledGuestAgentEntry? {
        entries[BundledGuestAgentKey(os, architecture, scope)]
    }

    /// The update payloads bundled for `os`, in scope order, each with the manifest the host offers a peer
    /// it fits (`BundledPayload.offer(from:for:)`): the file's digest with the entry's own format and label.
    /// Each file is hashed once per process, off the main actor, on the first ask, and never re-read; the
    /// guest verifies the payload's hash before it installs one, so a file changed since is refused, not
    /// installed. A file that cannot be read is logged and left out.
    package func payloads(for os: OSFamily) async -> [BundledPayload] {
        var payloads: [BundledPayload] = []
        let keys = entries.keys.filter { $0.os == os }.sorted { $0.scope.rawValue < $1.scope.rawValue }
        for key in keys {
            guard let entry = entries[key], case .payload(let format, let versionLabel) = entry.kind,
                let digest = await digests.digest(of: entry.fileURL)
            else { continue }
            payloads.append(
                BundledPayload(
                    os: key.os, architecture: key.architecture, scope: key.scope,
                    manifest: UpdateManifestValue(
                        payloadHash: digest.sha256, payloadSize: digest.byteCount, format: format,
                        versionLabel: versionLabel)))
        }
        return payloads
    }

    /// The file `manifest` was made from, among the payloads bundled for `os`; nil when none was.
    package func payloadFile(for manifest: UpdateManifestValue, os: OSFamily) async -> URL? {
        for (key, entry) in entries where key.os == os {
            guard case .payload = entry.kind, let digest = await digests.digest(of: entry.fileURL),
                digest.sha256 == manifest.payloadHash
            else { continue }
            return entry.fileURL
        }
        return nil
    }

    // MARK: Installer disks

    /// Whether this build bundles an installer disk for a `guestOS` guest: the macOS agent's DMG, or the
    /// Linux agent the disk is made from.
    package func bundlesInstallerDisk(for guestOS: VMGuestOS) -> Bool {
        switch guestOS {
        case .macOS: macOS != nil
        case .linux: entry(.linux, .arm64, .user) != nil
        }
    }

    /// The installer disk for a `guestOS` guest: the macOS agent's DMG, or the Linux agent's disk, made on
    /// this process's first ask; nil when ``bundlesInstallerDisk(for:)`` is false.
    package func installerDisk(for guestOS: VMGuestOS) async throws -> URL? {
        switch guestOS {
        case .macOS:
            return macOSInstallerDiskImageURL
        case .linux:
            guard let agent = entry(.linux, .arm64, .user) else { return nil }
            return try await linuxDisk.disk(agent: agent.fileURL)
        }
    }

    /// The label an attachment of `guestOS`'s installer disk carries: the volume name the guest shows.
    package static func installerDiskLabel(for guestOS: VMGuestOS) -> String {
        switch guestOS {
        case .macOS: macOSDiskLabel
        case .linux: LinuxAgentDisk.volumeLabel
        }
    }

    /// Whether `path` names one of the installer disks: an app-owned file, which detaching never trashes
    /// and deleting a VM never offers.
    package func isInstallerDisk(path: String) -> Bool {
        path == macOSInstallerDiskImageURL?.path(percentEncoded: false)
            || path == linuxDisk.url.path(percentEncoded: false)
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

/// Each payload file's SHA-256 and size, computed once per process on the first ask and never re-read.
private final class FileDigests: Sendable {
    struct Digest: Sendable {
        var sha256: Data
        var byteCount: UInt64
    }

    private let tasks = Mutex<[URL: Task<Digest?, Never>]>([:])

    func digest(of url: URL) async -> Digest? {
        let task = tasks.withLock { tasks in
            if let task = tasks[url] { return task }
            let task = Task { () async -> Digest? in
                do {
                    let digest = try await FileDigest.digest(of: url, priority: .utility)
                    return Digest(sha256: digest.sha256, byteCount: digest.byteCount)
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
