import Foundation

@testable import KernovaCore

extension BundledGuestAgent {
    /// An agent at version 2.0 whose installer image is a path nothing reads
    /// or writes: a test sees what the core would do to it through its
    /// `MockFileSystem`.
    package static let testing = BundledGuestAgent(
        version: "2.0",
        installerDiskImageURL: URL(filePath: "/Applications/Kernova.app/Contents/Resources/KernovaMacOSAgent.dmg"))
}
