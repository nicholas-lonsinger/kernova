import Foundation

@testable import KernovaCore

extension BundledGuestAgent {
    /// An agent at version 2.0 whose installer image is an empty file in the
    /// temporary directory, there for as long as a test asks whether it still
    /// is.
    package static let testing: BundledGuestAgent = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaTests-BundledGuestAgent", isDirectory: true)
        let installer = directory.appendingPathComponent("KernovaMacOSAgent.dmg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: installer.path(percentEncoded: false)) {
                try Data().write(to: installer)
            }
        } catch {
            preconditionFailure("The testing guest agent's installer could not be written: \(error)")
        }
        return BundledGuestAgent(version: "2.0", installerDiskImageURL: installer)
    }()
}
