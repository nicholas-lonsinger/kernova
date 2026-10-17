import Foundation

@testable import KernovaCore

extension BundledGuestAgent {
    /// An agent at version 2.0 whose installer image names no file: it is
    /// under `/var/empty`, the root-owned directory macOS keeps empty, so no
    /// path the core is handed for it reaches a real file.
    package static let testing = BundledGuestAgent(
        version: "2.0", installerDiskImageURL: URL(filePath: "/var/empty/KernovaMacOSAgent.dmg"))
}
