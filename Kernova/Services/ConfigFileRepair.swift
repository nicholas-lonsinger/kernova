import Foundation
import KernovaLogging

/// How putting the defaults in place in one config file ended, when it did
/// not throw.
enum ConfigFileRepair: Sendable, Equatable {
    /// The file holds its defaults now, and what it held is in the Trash.
    case repaired
    /// The file reads as it is: something else fixed it since the check, and
    /// it was left alone.
    case alreadyReadable

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "ConfigFileRepair")

    /// Moves a copy of `data` to the Trash as a file named `name` — what a
    /// repair does with the bytes it replaces, before it replaces them.
    ///
    /// The copy is written to a directory of its own under the temporary
    /// directory, which is app-internal and removed outright afterwards.
    static func moveOriginalToTrash(
        _ data: Data, named name: String, using fileSystem: any FileSystemOperating
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigFileOriginal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                #log(
                    logger, .warning,
                    "Could not remove \(directory.lastPathComponent, privacy: .public) after moving a config file's original to the Trash: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let copy = directory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: copy)
        try fileSystem.trashItem(at: copy)
    }
}

/// Why a repair left a config file as it was.
enum ConfigFileRepairRefusal: LocalizedError, Equatable {
    /// What the file holds now has a problem with no default, or is gone.
    case notRepairable
    /// A copy of Kernova holds the bundle's run lock.
    case inUse

    var errorDescription: String? {
        switch self {
        case .notRepairable:
            "The file changed since the check, and Kernova can\u{2019}t repair what it holds now."
        case .inUse:
            "A copy of Kernova is using the virtual machine."
        }
    }
}
