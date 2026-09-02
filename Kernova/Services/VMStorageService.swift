import Foundation
import os

/// Manages VM bundle directories on disk under `~/Library/Application Support/Kernova/VMs/`.
///
/// Each VM is a `.kernova` document package named by its UUID; `VMBundleLayout`
/// owns the names of the files inside it.
struct VMStorageService: Sendable {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMStorageService")

    static let bundleExtension = "kernova"

    /// Whether `url` looks like a `.kernova` bundle, by extension.
    static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension == bundleExtension
    }

    // MARK: - Directory Helpers

    /// The `Application Support/Kernova` root every app-level store hangs off —
    /// the single derivation of the path, so stores can never strand each other
    /// by recomputing it differently.
    static var supportDirectory: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Kernova", isDirectory: true)
        }
    }

    var vmsDirectory: URL {
        get throws {
            let vmsDir = try Self.supportDirectory.appendingPathComponent("VMs", isDirectory: true)

            if !FileManager.default.fileExists(atPath: vmsDir.path(percentEncoded: false)) {
                try FileManager.default.createDirectory(at: vmsDir, withIntermediateDirectories: true)
            }
            return vmsDir
        }
    }

    func bundleURL(for configuration: VMConfiguration) throws -> URL {
        try vmsDirectory.appendingPathComponent(
            "\(configuration.id.uuidString).\(Self.bundleExtension)",
            isDirectory: true
        )
    }

    /// Where a bundle still being written lives until ``publishBundle(from:to:)``
    /// renames the finished tree into `vmsDirectory`.
    ///
    /// Inside `vmsDirectory` so publication is a same-volume rename rather than a
    /// second copy, and dot-prefixed so the hidden-skipping enumerations —
    /// ``listVMBundles()`` and the import destination reservation — never see a
    /// tree that is still growing.
    var stagingDirectory: URL {
        get throws {
            let staging = try vmsDirectory.appendingPathComponent(".Staging", isDirectory: true)

            if !FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)) {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            }
            return staging
        }
    }

    /// A fresh staged path for one create, clone or import to build its bundle at.
    ///
    /// Named for a UUID minted here rather than the configuration's: an import
    /// keeps the source bundle's id, so a configuration id would give a retried
    /// import the same path as the interrupted attempt whose tree the launch
    /// reclaim is still deleting. A per-write name cannot collide with anything.
    /// The directory does not exist, which import's `copyItem` requires.
    func makeStagedBundleURL() throws -> URL {
        try stagingDirectory.appendingPathComponent(
            "\(UUID().uuidString).\(Self.bundleExtension)",
            isDirectory: true
        )
    }

    /// Renames a finished staged bundle into `vmsDirectory`, the single instant at
    /// which a write becomes a VM the library can load.
    ///
    /// The rename is the collision guard: `moveItem` refuses an occupied
    /// destination, so nothing between a check and the move can take the name.
    func publishBundle(from stagedURL: URL, to bundleURL: URL) throws {
        do {
            try FileManager.default.moveItem(at: stagedURL, to: bundleURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
        {
            throw VMStorageError.bundleAlreadyExists(bundleURL)
        }
        Self.logger.notice(
            "Published VM bundle \(bundleURL.lastPathComponent, privacy: .public)")
    }

    /// Discards every staged bundle an earlier run left behind, returning the
    /// task its removals run on.
    ///
    /// An interrupted write leaves a tree whose payload is incomplete and whose
    /// source still exists, so it is removed outright rather than trashed. The
    /// enumeration is synchronous — one `readdir` — while the removals run
    /// detached, because a staged tree can be multi-gigabyte and this runs at
    /// launch. Nothing has to await the returned task: every staged name is
    /// minted per write, so a removal still in flight can never name a path this
    /// run is about to use.
    @discardableResult
    func reclaimStagedBundles() -> Task<Void, Never> {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: try stagingDirectory, includingPropertiesForKeys: nil, options: [])
        } catch {
            Self.logger.warning(
                "Could not enumerate staged VM bundles: \(error.localizedDescription, privacy: .public)"
            )
            return Task {}
        }

        return Task.detached {
            for entry in entries {
                do {
                    try FileManager.default.removeItem(at: entry)
                    Self.logger.notice(
                        "Reclaimed the staged bundle an interrupted write left at \(entry.lastPathComponent, privacy: .public)"
                    )
                } catch {
                    Self.logger.warning(
                        "Could not reclaim the staged bundle at \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    // MARK: - CRUD

    /// Lists the bundle directories under `vmsDirectory` that hold a config file.
    func listVMBundles() throws -> [URL] {
        let dir = try vmsDirectory
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { url in
            let configFile = VMBundleLayout(bundleURL: url).configURL
            return FileManager.default.fileExists(atPath: configFile.path(percentEncoded: false))
        }
    }

    func loadConfiguration(from bundleURL: URL) throws -> VMConfiguration {
        try VMConfiguration.load(fromBundle: bundleURL)
    }

    func saveConfiguration(_ configuration: VMConfiguration, to bundleURL: URL) throws {
        let configURL = VMBundleLayout(bundleURL: bundleURL).configURL
        let data = try VMConfiguration.makeJSONEncoder().encode(configuration)
        try data.write(to: configURL, options: .atomic)
        Self.logger.info(
            "Saved configuration for VM '\(configuration.name, privacy: .public)' to \(bundleURL.lastPathComponent, privacy: .public)"
        )
    }

    /// Creates a new VM bundle directory at `bundleURL` and saves the initial configuration.
    ///
    /// Every caller writes into a freshly minted ``makeStagedBundleURL()``; the
    /// collision guard is the rename in ``publishBundle(from:to:)``.
    func createVMBundle(_ configuration: VMConfiguration, at bundleURL: URL) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try saveConfiguration(configuration, to: bundleURL)

        Self.logger.notice(
            "Created VM bundle for '\(configuration.name, privacy: .public)' at \(bundleURL.lastPathComponent, privacy: .public)"
        )
    }

    func cloneVMBundle(
        from sourceBundleURL: URL, to destinationBundleURL: URL, newConfiguration: VMConfiguration,
        filesToCopy: [String]
    ) throws {
        try FileManager.default.createDirectory(at: destinationBundleURL, withIntermediateDirectories: true)

        let fm = FileManager.default
        for fileName in filesToCopy {
            let sourceFile = sourceBundleURL.appendingPathComponent(fileName)
            let destinationFile = destinationBundleURL.appendingPathComponent(fileName)
            if fm.fileExists(atPath: sourceFile.path(percentEncoded: false)) {
                try fm.copyItem(at: sourceFile, to: destinationFile)
            }
        }

        try saveConfiguration(newConfiguration, to: destinationBundleURL)

        Self.logger.notice(
            "Cloned VM bundle from '\(sourceBundleURL.lastPathComponent, privacy: .public)' to '\(destinationBundleURL.lastPathComponent, privacy: .public)'"
        )
    }

    /// Moves a VM bundle and everything in it to the Trash.
    func deleteVMBundle(at bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)) else {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        try FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        Self.logger.notice("Moved VM bundle to Trash: \(bundleURL.lastPathComponent, privacy: .public)")
    }

    /// Permanently deletes a VM bundle directory and all its contents, bypassing the Trash.
    func permanentlyDeleteVMBundle(at bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)) else {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        try FileManager.default.removeItem(at: bundleURL)
        Self.logger.notice("Permanently deleted VM bundle: \(bundleURL.lastPathComponent, privacy: .public)")
    }
}

// MARK: - VMStorageProviding

extension VMStorageService: VMStorageProviding {}

// MARK: - Errors

enum VMStorageError: LocalizedError {
    case bundleAlreadyExists(URL)
    case bundleNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .bundleAlreadyExists(let url):
            "A VM bundle already exists at \(url.path(percentEncoded: false))."
        case .bundleNotFound(let url):
            "VM bundle not found at \(url.path(percentEncoded: false))."
        }
    }
}
