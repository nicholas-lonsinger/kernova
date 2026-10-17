import Foundation

@testable import KernovaCore

extension BundledGuestAgent {
    /// An agent at version 2.0 whose installer image names no file: it is
    /// under `/var/empty`, the root-owned directory macOS keeps empty, so no
    /// path the core is handed for it reaches a real file.
    package static let testing = BundledGuestAgent(
        version: "2.0", installerDiskImageURL: URL(filePath: "/var/empty/KernovaMacOSAgent.dmg"))
}

extension AppBundleProducts {
    /// The products of an app under `/var/empty`, which holds none — no disk
    /// template, relaunch helper or tool — at host version 1.0 build 1, bundling
    /// ``BundledGuestAgent/testing``.
    package static let testing = AppBundleProducts(
        bundleURL: URL(filePath: "/var/empty/Kernova.app", directoryHint: .isDirectory),
        hostVersion: "1.0", buildNumber: "1", guestAgent: .testing)
}
