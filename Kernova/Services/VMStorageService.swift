import Foundation
import os

/// Manages VM bundle directories on disk under `~/Library/Application Support/Kernova/VMs/`.
///
/// Each VM is stored as a `.kernova` document package named by its UUID, containing:
/// - `config.json` — Serialized `VMConfiguration`
/// - `Disk.asif` — ASIF sparse disk image
/// - macOS-specific files: `AuxiliaryStorage`, `HardwareModel`, `MachineIdentifier`
/// - Optional: `SaveFile.vzvmsave`
struct VMStorageService: Sendable {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMStorageService")

    static let bundleExtension = "kernova"

    // MARK: - Directory Helpers

    /// The root directory for all VM bundles.
    var vmsDirectory: URL {
        get throws {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let vmsDir = appSupport
                .appendingPathComponent("Kernova", isDirectory: true)
                .appendingPathComponent("VMs", isDirectory: true)

            if !FileManager.default.fileExists(atPath: vmsDir.path) {
                try FileManager.default.createDirectory(at: vmsDir, withIntermediateDirectories: true)
            }
            return vmsDir
        }
    }

    /// Returns the bundle directory URL for a given VM configuration.
    func bundleURL(for configuration: VMConfiguration) throws -> URL {
        try vmsDirectory.appendingPathComponent(
            "\(configuration.id.uuidString).\(Self.bundleExtension)",
            isDirectory: true
        )
    }

    // MARK: - CRUD

    /// Lists all VM bundle directories.
    func listVMBundles() throws -> [URL] {
        let dir = try vmsDirectory
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { url in
            let configFile = url.appendingPathComponent("config.json")
            return FileManager.default.fileExists(atPath: configFile.path)
        }
    }

    /// Loads a `VMConfiguration` from a bundle directory.
    func loadConfiguration(from bundleURL: URL) throws -> VMConfiguration {
        let configURL = bundleURL.appendingPathComponent("config.json")
        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VMConfiguration.self, from: data)
    }

    /// Saves a `VMConfiguration` to a bundle directory.
    func saveConfiguration(_ configuration: VMConfiguration, to bundleURL: URL) throws {
        let configURL = bundleURL.appendingPathComponent("config.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: configURL, options: .atomic)
        Self.logger.info("Saved configuration for VM '\(configuration.name)' to \(bundleURL.lastPathComponent)")
    }

    /// Creates a new VM bundle directory and saves the initial configuration.
    func createVMBundle(for configuration: VMConfiguration) throws -> URL {
        let bundle = try bundleURL(for: configuration)

        if FileManager.default.fileExists(atPath: bundle.path) {
            throw VMStorageError.bundleAlreadyExists(configuration.id)
        }

        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try saveConfiguration(configuration, to: bundle)

        Self.logger.info("Created VM bundle for '\(configuration.name)' at \(bundle.lastPathComponent)")
        return bundle
    }

    /// Clones a VM bundle by creating a new bundle directory and copying specified files.
    func cloneVMBundle(from sourceBundleURL: URL, newConfiguration: VMConfiguration, filesToCopy: [String]) throws -> URL {
        let destinationBundle = try bundleURL(for: newConfiguration)

        if FileManager.default.fileExists(atPath: destinationBundle.path) {
            throw VMStorageError.bundleAlreadyExists(newConfiguration.id)
        }

        try FileManager.default.createDirectory(at: destinationBundle, withIntermediateDirectories: true)

        let fm = FileManager.default
        for fileName in filesToCopy {
            let sourceFile = sourceBundleURL.appendingPathComponent(fileName)
            let destinationFile = destinationBundle.appendingPathComponent(fileName)
            if fm.fileExists(atPath: sourceFile.path) {
                try fm.copyItem(at: sourceFile, to: destinationFile)
            }
        }

        try saveConfiguration(newConfiguration, to: destinationBundle)

        Self.logger.info("Cloned VM bundle from '\(sourceBundleURL.lastPathComponent)' to '\(destinationBundle.lastPathComponent)'")
        return destinationBundle
    }

    /// Deletes a VM bundle directory and all its contents.
    func deleteVMBundle(at bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        try FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        Self.logger.info("Moved VM bundle to Trash: \(bundleURL.lastPathComponent)")
    }

    /// Migrates a legacy bare-UUID bundle directory to the `.kernova` package format.
    ///
    /// - If the URL already has the `.kernova` extension, returns it unchanged.
    /// - If a bare `{UUID}` directory exists without a `.kernova` counterpart, renames it.
    /// - If both `{UUID}` and `{UUID}.kernova` exist, throws `migrationConflict`.
    func migrateBundleIfNeeded(at bundleURL: URL) throws -> URL {
        if bundleURL.pathExtension == Self.bundleExtension {
            return bundleURL
        }

        let migratedURL = bundleURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(bundleURL.lastPathComponent).\(Self.bundleExtension)",
                isDirectory: true
            )

        let fm = FileManager.default
        let legacyExists = fm.fileExists(atPath: bundleURL.path)
        let migratedExists = fm.fileExists(atPath: migratedURL.path)

        if legacyExists && migratedExists {
            throw VMStorageError.migrationConflict(bundleURL)
        }

        if legacyExists {
            try fm.moveItem(at: bundleURL, to: migratedURL)
            Self.logger.info("Migrated VM bundle: \(bundleURL.lastPathComponent) → \(migratedURL.lastPathComponent)")
        }

        return migratedURL
    }
}

// MARK: - VMStorageProviding

extension VMStorageService: VMStorageProviding {}

// MARK: - Errors

enum VMStorageError: LocalizedError {
    case bundleAlreadyExists(UUID)
    case bundleNotFound(URL)
    case migrationConflict(URL)

    var errorDescription: String? {
        switch self {
        case .bundleAlreadyExists(let id):
            "A VM bundle already exists for ID \(id.uuidString)."
        case .bundleNotFound(let url):
            "VM bundle not found at \(url.path)."
        case .migrationConflict(let url):
            "Migration conflict: both legacy and .kernova bundles exist for \(url.lastPathComponent)."
        }
    }
}
