import Foundation
import KernovaAgentCore

@testable import KernovaCore

extension BundledGuestAgents {
    /// A macOS agent at version 2.0 whose installer image names no file: it is
    /// under `/var/empty`, the root-owned directory macOS keeps empty, so no
    /// path the core is handed for it reaches a real file. No Linux agent.
    package static let testing = macOS(
        version: "2.0", installerDiskImageURL: URL(filePath: "/var/empty/KernovaMacOSAgent.dmg"))

    /// Only a macOS agent at `version` with its installer at
    /// `installerDiskImageURL`, or no agent at all when that is `nil`.
    package static func macOS(version: String, installerDiskImageURL: URL?) -> BundledGuestAgents {
        BundledGuestAgents(
            entries: installerDiskImageURL.map { url in
                [
                    BundledGuestAgentEntry(
                        os: .macOS, architecture: .arm64, scope: .user, fileURL: url,
                        kind: .installerDisk(version: version))
                ]
            } ?? [])
    }
}

extension AppBundleProducts {
    /// The products of an app under `/var/empty`, which holds none — no disk
    /// template, relaunch helper or tool — at host version 1.0 build 1, bundling
    /// ``BundledGuestAgents/testing``.
    package static let testing = AppBundleProducts(
        bundleURL: URL(filePath: "/var/empty/Kernova.app", directoryHint: .isDirectory),
        hostVersion: "1.0", buildNumber: "1", guestAgents: .testing)
}
