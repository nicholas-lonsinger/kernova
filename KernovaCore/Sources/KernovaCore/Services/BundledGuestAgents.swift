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

/// One guest agent this copy of Kernova bundles: an update payload, identified by its SHA-256, which
/// ``BundledGuestAgents/payloads(for:)`` computes.
package struct BundledGuestAgentEntry: Sendable, Equatable {
    /// The file in the app bundle.
    package let fileURL: URL
    /// How the payload is packed.
    package let format: PayloadFormat
    /// The display version it installs.
    package let versionLabel: String
    /// Whether the host offers it as an in-band update to an agent that runs another payload.
    ///
    /// A macOS agent offers it only when the build signed it with a team. An installed agent's launch
    /// constraint is built from its designated requirement, which for an ad-hoc signature is its own cdhash,
    /// so launchd kills a relaunch into any other build ("Launch Constraint Violation"). With this false, the
    /// guest is told no update is available: its agents keep running the build they were installed from, the
    /// host shows them by version rather than as out of date, and the installer disk is what puts this build's
    /// agent in the guest.
    package let updatesInBand: Bool

    package init(fileURL: URL, format: PayloadFormat, versionLabel: String, updatesInBand: Bool) {
        self.fileURL = fileURL
        self.format = format
        self.versionLabel = versionLabel
        self.updatesInBand = updatesInBand
    }
}

/// The guest agents a host bundles, one per (OS family, architecture, install scope), each an update payload
/// serving both the user and the system scope from one file: the macOS agent's container tree, and the Linux
/// `kernova-agent`. Beside them, the macOS installer disk the user runs inside the guest. A file the bundle
/// lacks has no entry, so what it would deliver is not offered.
///
/// One of the ``AppBundleProducts``, which reads the app's.
package struct BundledGuestAgents: Sendable {
    /// Label every attachment of the macOS installer image carries, matching the volume name the "Package
    /// Guest Agent DMG" build phase gives it — so the name Kernova shows for the attachment is the name the
    /// guest shows for the mounted volume.
    package static let macOSDiskLabel = "Kernova Guest Agent"

    /// Where the bundle carries the Linux agent, under its Resources.
    static let linuxAgentPath = "GuestAgents/linux-arm64/kernova-agent"

    /// Where the bundle carries the macOS agent's update payload, under its Resources.
    static let macOSAgentPath = "GuestAgents/macos-arm64/agent.payload"

    /// Where the bundle records the macOS agent's signing team, under its Resources: a property list whose
    /// `TeamIdentifier` the "Package Guest Agent DMG" build phase reads from the agent's signature, and leaves
    /// out for an ad-hoc one.
    static let macOSAgentSigningPath = "GuestAgents/macos-arm64/agent.signing.plist"

    /// Where the bundle carries the macOS installer disk, under its Resources.
    static let macOSInstallerDiskPath = "KernovaMacOSAgent.dmg"

    /// The payloads a bundle carries: where, for which OS family and architecture, packed how, and where
    /// the build records its signing team — `nil` for a payload no launch constraint holds to its signature,
    /// which always updates in band.
    private static let payloadFiles:
        [(path: String, os: OSFamily, architecture: Architecture, format: PayloadFormat, signingPath: String?)] = [
            (macOSAgentPath, .macOS, .arm64, .containerTree, macOSAgentSigningPath),
            (linuxAgentPath, .linux, .arm64, .executable, nil),
        ]

    /// Every entry, by what it installs onto.
    package let entries: [BundledGuestAgentKey: BundledGuestAgentEntry]

    /// The macOS agent's installer DMG, or `nil` when none is bundled.
    package let macOSInstallerDiskImageURL: URL?

    /// Where the Linux agent's installer disk is made.
    package let linuxDisk: GuestAgentDiskCache

    private let digests: FileDigests

    package init(
        entries: [BundledGuestAgentKey: BundledGuestAgentEntry], macOSInstallerDiskImageURL: URL?,
        linuxDisk: GuestAgentDiskCache
    ) {
        self.entries = entries
        self.macOSInstallerDiskImageURL = macOSInstallerDiskImageURL
        self.linuxDisk = linuxDisk
        self.digests = FileDigests()
    }

    /// The agents `bundle` carries; `versionLabel` is the display version of the payloads the bundle's own
    /// build labelled. Every build bundles both agents and the macOS installer disk, so one missing is a
    /// packaging defect.
    init(bundle: Bundle, versionLabel: String) {
        let entries = Self.entries(in: bundle, versionLabel: versionLabel)
        for file in Self.payloadFiles where entries[BundledGuestAgentKey(file.os, file.architecture, .user)] == nil {
            Self.reportMissing(file.path)
        }
        let disk = Self.resource(Self.macOSInstallerDiskPath, in: bundle)
        if disk == nil { Self.reportMissing(Self.macOSInstallerDiskPath) }
        self.init(entries: entries, macOSInstallerDiskImageURL: disk, linuxDisk: .production)
    }

    /// The entries for the payloads `bundle` carries.
    static func entries(in bundle: Bundle, versionLabel: String) -> [BundledGuestAgentKey: BundledGuestAgentEntry] {
        var entries: [BundledGuestAgentKey: BundledGuestAgentEntry] = [:]
        for file in payloadFiles {
            guard let url = resource(file.path, in: bundle) else { continue }
            let updatesInBand = file.signingPath.map { isTeamSigned(recordedAt: $0, in: bundle) } ?? true
            for scope in [InstallScope.user, .system] {
                entries[BundledGuestAgentKey(file.os, file.architecture, scope)] = BundledGuestAgentEntry(
                    fileURL: url, format: file.format, versionLabel: versionLabel, updatesInBand: updatesInBand)
            }
        }
        return entries
    }

    /// Whether the signing record at `path` under `bundle` names a team; a record the bundle lacks or that
    /// does not read is a packaging defect, and names none.
    private static func isTeamSigned(recordedAt path: String, in bundle: Bundle) -> Bool {
        struct Signing: Decodable {
            var teamIdentifier: String?

            enum CodingKeys: String, CodingKey {
                case teamIdentifier = "TeamIdentifier"
            }
        }
        guard let url = resource(path, in: bundle) else {
            reportMissing(path)
            return false
        }
        do {
            let signing = try PropertyListDecoder().decode(Signing.self, from: Data(contentsOf: url))
            return signing.teamIdentifier?.isEmpty == false
        } catch {
            logger.log(
                .fault, "\(path, privacy: .public) does not read: \(error.localizedDescription, privacy: .public)")
            assertionFailure("\(path) does not read: \(error)")
            return false
        }
    }

    /// The file at `path` under `bundle`'s Resources, or `nil` when it carries none.
    private static func resource(_ path: String, in bundle: Bundle) -> URL? {
        guard let slash = path.lastIndex(of: "/") else {
            return bundle.url(forResource: path, withExtension: nil)
        }
        return bundle.url(
            forResource: String(path[path.index(after: slash)...]), withExtension: nil,
            subdirectory: String(path[..<slash]))
    }

    private static func reportMissing(_ path: String) {
        logger.log(.fault, "\(path, privacy: .public) missing from app bundle")
        assertionFailure("\(path) missing from app bundle — check the build phase that writes it")
    }

    /// The entry for `os`, `architecture` and `scope`, or nil when none is bundled.
    package func entry(
        _ os: OSFamily, _ architecture: Architecture, _ scope: InstallScope
    ) -> BundledGuestAgentEntry? {
        entries[BundledGuestAgentKey(os, architecture, scope)]
    }

    /// The update payloads bundled for `os`, in scope order, each with the manifest the host judges a peer it
    /// fits by and, when the entry updates in band, offers it (`BundledPayload.offer(from:for:)`): the file's
    /// digest with the entry's own format and label.
    /// Each file is hashed once per process, off the main actor, on the first ask, and never re-read; the
    /// guest verifies the payload's hash before it installs one, so a file changed since is refused, not
    /// installed. A file that cannot be read is logged and left out.
    package func payloads(for os: OSFamily) async -> [BundledPayload] {
        var payloads: [BundledPayload] = []
        let keys = entries.keys.filter { $0.os == os }.sorted { $0.scope.rawValue < $1.scope.rawValue }
        for key in keys {
            guard let entry = entries[key], let digest = await digests.digest(of: entry.fileURL) else { continue }
            payloads.append(
                BundledPayload(
                    os: key.os, architecture: key.architecture, scope: key.scope,
                    manifest: UpdateManifestValue(
                        payloadHash: digest.sha256, payloadSize: digest.byteCount, format: entry.format,
                        versionLabel: entry.versionLabel),
                    updatesInBand: entry.updatesInBand))
        }
        return payloads
    }

    /// The SHA-256 of the payload bundled for each guest OS that has one: the hash
    /// ``payloads(for:)`` offers, which a peer running it claims.
    package func payloadHashes() async -> [VMGuestOS: Data] {
        var hashes: [VMGuestOS: Data] = [:]
        for guestOS in VMGuestOS.allCases {
            if let payload = await payloads(for: OSFamily(guestOS)).first {
                hashes[guestOS] = payload.manifest.payloadHash
            }
        }
        return hashes
    }

    /// The file `manifest` was made from, among the payloads bundled for `os`; nil when none was.
    package func payloadFile(for manifest: UpdateManifestValue, os: OSFamily) async -> URL? {
        for (key, entry) in entries where key.os == os {
            guard let digest = await digests.digest(of: entry.fileURL), digest.sha256 == manifest.payloadHash
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
        case .macOS: macOSInstallerDiskImageURL != nil
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

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "BundledGuestAgents")
}

extension OSFamily {
    /// The OS family of a `guestOS` guest.
    init(_ guestOS: VMGuestOS) {
        self =
            switch guestOS {
            case .macOS: .macOS
            case .linux: .linux
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
