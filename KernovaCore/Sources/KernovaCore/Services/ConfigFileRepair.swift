import Foundation
import KernovaKit
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

    /// What a repair of `checked` writes over the file, given what the file
    /// holds now — `current`, `nil` when there is no file — or `nil` when
    /// the file reads as it is, which `reads` decides. Every repair decides
    /// through this, inside the coordinated write that makes it.
    ///
    /// Refuses bytes other than the ones the check reported, so a repair
    /// acts only on what the user reviewed.
    static func replacement(
        for checked: UnreadableConfigFile, current: Data?, reads: (Data?) -> Bool,
        diagnose: (Data) -> ConfigFileDiagnosis
    ) throws(ConfigFileRepairRefusal) -> Replacement? {
        if reads(current) { return nil }
        guard let current, let digest = checked.checkedDigest, ConfigFileDigest(of: current) == digest else {
            throw .changedSinceCheck
        }
        guard let repaired = diagnose(current).repaired else { throw .notRepairable }
        return Replacement(original: current, repaired: repaired)
    }

    /// The bytes a repair replaces, and what it writes in their place.
    struct Replacement {
        let original: Data
        let repaired: Data
    }

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
    /// The file holds bytes other than the ones the check reported — or none
    /// where it must hold some — so what it holds now has not been reviewed.
    case changedSinceCheck
    /// The file has a problem with no repair.
    case notRepairable
    /// A copy of Kernova holds the bundle's run lock.
    case inUse
    /// The bundle a move to the Trash was asked for reads now, so it is a
    /// virtual machine again.
    case readsNow

    var errorDescription: String? {
        switch self {
        case .changedSinceCheck:
            "The file changed since the check. Review what it holds now."
        case .notRepairable:
            "Kernova can\u{2019}t repair this file."
        case .inUse:
            "A copy of Kernova is using the virtual machine."
        case .readsNow:
            "Kernova can read this virtual machine now. To remove it, delete it from the library."
        }
    }
}
