import Foundation
import KernovaKit
import KernovaLogging

/// Manages VM bundle directories on disk under `~/Library/Application Support/Kernova/VMs/`.
///
/// Each VM is a `.kernova` document package named by its UUID; `VMBundleLayout`
/// owns the names of the files inside it.
struct VMStorageService: Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMStorageService")

    /// Whether `url` looks like a `.kernova` bundle, by extension.
    static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension == VMBundleFormat.fileExtension
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

    var bundleFiles: any VMBundleFileAccessing { CoordinatedBundleFileAccess() }

    func bundleURL(for configuration: VMConfiguration) throws -> URL {
        try vmsDirectory.appendingPathComponent(
            "\(configuration.id.uuidString).\(VMBundleFormat.fileExtension)",
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
            "\(UUID().uuidString).\(VMBundleFormat.fileExtension)",
            isDirectory: true
        )
    }

    /// Renames a finished staged bundle into `vmsDirectory`, the single instant at
    /// which a write becomes a VM the library can load.
    ///
    /// `renamex_np` with `RENAME_EXCL` is the collision guard: the kernel returns
    /// `EEXIST` for an occupied destination — an empty or non-empty directory, or
    /// a file — in the same call that renames. `FileManager.moveItem` checks
    /// first and renames after, so a concurrent publish to the same name can win
    /// the gap, and the loser fails with Cocoa error 512 over `ENOTEMPTY`
    /// (`docs/research/2026-09-24-file-coordination-rename-and-flock.md`,
    /// "Moving a staged directory into place").
    ///
    /// - Throws: ``VMStorageError/bundleAlreadyExists(_:)`` when the destination
    ///   is occupied; a `POSIXError` for any other failure.
    func publishBundle(from stagedURL: URL, to bundleURL: URL) throws {
        let result = stagedURL.withUnsafeFileSystemRepresentation { source in
            bundleURL.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return ENAMETOOLONG }
                return renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        switch result {
        case 0:
            break
        case EEXIST:
            throw VMStorageError.bundleAlreadyExists(bundleURL)
        default:
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        #log(
            Self.logger, .notice,
            "Published VM bundle \(bundleURL.lastPathComponent, privacy: .public)")
    }

    func bundleIdentity(at bundleURL: URL) -> VMBundleIdentity? {
        VMBundleIdentity(bundleAt: bundleURL)
    }

    /// Removes a staged tree outright: its payload is incomplete or unpublished,
    /// and its source still exists.
    func discardStagedBundle(at stagedURL: URL) throws {
        try FileManager.default.removeItem(at: stagedURL)
        #log(
            Self.logger, .notice,
            "Discarded the staged bundle at \(stagedURL.lastPathComponent, privacy: .public)")
    }

    /// Discards every staged bundle an earlier run left behind, returning the
    /// task its removals run on.
    ///
    /// An interrupted write leaves a tree whose payload is incomplete and whose
    /// source still exists, so it is discarded outright rather than trashed. The
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
            #log(
                Self.logger, .warning,
                "Could not enumerate staged VM bundles: \(error.localizedDescription, privacy: .public)"
            )
            return Task {}
        }

        return Task.detached {
            for entry in entries {
                do {
                    try discardStagedBundle(at: entry)
                } catch {
                    #log(
                        Self.logger, .warning,
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

    /// Creates a new, empty VM bundle directory at `bundleURL`.
    ///
    /// Every caller writes into a freshly minted ``makeStagedBundleURL()``; the
    /// collision guard is the rename in ``publishBundle(from:to:)``.
    func createVMBundle(at bundleURL: URL) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        #log(
            Self.logger, .notice,
            "Created VM bundle directory \(bundleURL.lastPathComponent, privacy: .public)")
    }

    /// Creates `destinationBundleURL` and copies `filesToCopy` into it from the
    /// source bundle, skipping any the source lacks; the clone writes its own
    /// configuration.
    func cloneVMBundle(
        from sourceBundleURL: URL, to destinationBundleURL: URL, filesToCopy: [String]
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

        #log(
            Self.logger, .notice,
            "Cloned VM bundle from '\(sourceBundleURL.lastPathComponent, privacy: .public)' to '\(destinationBundleURL.lastPathComponent, privacy: .public)'"
        )
    }

    /// Moves a VM bundle and everything in it to the Trash.
    func deleteVMBundle(at bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)) else {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        try FileManager.default.trashItem(at: bundleURL, resultingItemURL: nil)
        #log(Self.logger, .notice, "Moved VM bundle to Trash: \(bundleURL.lastPathComponent, privacy: .public)")
    }

    /// Permanently deletes a VM bundle directory and all its contents, bypassing the Trash.
    func permanentlyDeleteVMBundle(at bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)) else {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        try FileManager.default.removeItem(at: bundleURL)
        #log(Self.logger, .notice, "Permanently deleted VM bundle: \(bundleURL.lastPathComponent, privacy: .public)")
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
