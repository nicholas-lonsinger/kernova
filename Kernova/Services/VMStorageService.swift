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
            let vmsDir =
                appSupport
                .appendingPathComponent("Kernova", isDirectory: true)
                .appendingPathComponent("VMs", isDirectory: true)

            if !FileManager.default.fileExists(atPath: vmsDir.path(percentEncoded: false)) {
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
            return FileManager.default.fileExists(atPath: configFile.path(percentEncoded: false))
        }
    }

    /// Loads a `VMConfiguration` from a bundle directory.
    ///
    /// Persists legacy field migrations atomically before returning, so the
    /// auto-generated `discImageDeviceUUID` is durable from this point on.
    /// Without this, a user who suspends a legacy VM and quits without
    /// editing settings would generate a fresh UUID on every launch and
    /// break save-state restore silently.
    func loadConfiguration(from bundleURL: URL) throws -> VMConfiguration {
        let configURL = bundleURL.appendingPathComponent("config.json")
        let data = try Data(contentsOf: configURL)

        // Detect the legacy migration condition before decoding: a config
        // saved before `discImageDeviceUUID` existed has `discImagePath` set
        // but no UUID key. The decoder will fill in a fresh UUID; we then
        // save the result back so the UUID is stable across launches.
        let needsLegacyDiscUUIDPersistence: Bool
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            needsLegacyDiscUUIDPersistence =
                json["discImagePath"] is String && json["discImageDeviceUUID"] == nil
        } else {
            needsLegacyDiscUUIDPersistence = false
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(VMConfiguration.self, from: data)

        if needsLegacyDiscUUIDPersistence {
            Self.logger.notice(
                "Persisting migrated discImageDeviceUUID for VM '\(configuration.name, privacy: .public)'"
            )
            try saveConfiguration(configuration, to: bundleURL)
        }

        return configuration
    }

    /// Saves a `VMConfiguration` to a bundle directory.
    func saveConfiguration(_ configuration: VMConfiguration, to bundleURL: URL) throws {
        let configURL = bundleURL.appendingPathComponent("config.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: configURL, options: .atomic)
        Self.logger.info(
            "Saved configuration for VM '\(configuration.name, privacy: .public)' to \(bundleURL.lastPathComponent, privacy: .public)"
        )
    }

    /// Creates a new VM bundle directory and saves the initial configuration.
    func createVMBundle(for configuration: VMConfiguration) throws -> URL {
        let bundle = try bundleURL(for: configuration)

        if FileManager.default.fileExists(atPath: bundle.path(percentEncoded: false)) {
            throw VMStorageError.bundleAlreadyExists(configuration.id)
        }

        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try saveConfiguration(configuration, to: bundle)

        Self.logger.notice(
            "Created VM bundle for '\(configuration.name, privacy: .public)' at \(bundle.lastPathComponent, privacy: .public)"
        )
        return bundle
    }

    /// Clones a VM bundle by creating a new bundle directory and copying specified files.
    func cloneVMBundle(from sourceBundleURL: URL, newConfiguration: VMConfiguration, filesToCopy: [String]) throws
        -> URL
    {
        let destinationBundle = try bundleURL(for: newConfiguration)

        if FileManager.default.fileExists(atPath: destinationBundle.path(percentEncoded: false)) {
            throw VMStorageError.bundleAlreadyExists(newConfiguration.id)
        }

        try FileManager.default.createDirectory(at: destinationBundle, withIntermediateDirectories: true)

        let fm = FileManager.default
        for fileName in filesToCopy {
            let sourceFile = sourceBundleURL.appendingPathComponent(fileName)
            let destinationFile = destinationBundle.appendingPathComponent(fileName)
            if fm.fileExists(atPath: sourceFile.path(percentEncoded: false)) {
                try fm.copyItem(at: sourceFile, to: destinationFile)
            }
        }

        try saveConfiguration(newConfiguration, to: destinationBundle)

        Self.logger.notice(
            "Cloned VM bundle from '\(sourceBundleURL.lastPathComponent, privacy: .public)' to '\(destinationBundle.lastPathComponent, privacy: .public)'"
        )
        return destinationBundle
    }

    /// Deletes a VM bundle directory and all its contents.
    func deleteVMBundle(at bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)) else {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        try FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        Self.logger.notice("Moved VM bundle to Trash: \(bundleURL.lastPathComponent, privacy: .public)")
    }
}

// MARK: - VMStorageProviding

extension VMStorageService: VMStorageProviding {}

// MARK: - Errors

enum VMStorageError: LocalizedError {
    case bundleAlreadyExists(UUID)
    case bundleNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .bundleAlreadyExists(let id):
            "A VM bundle already exists for ID \(id.uuidString)."
        case .bundleNotFound(let url):
            "VM bundle not found at \(url.path(percentEncoded: false))."
        }
    }
}
