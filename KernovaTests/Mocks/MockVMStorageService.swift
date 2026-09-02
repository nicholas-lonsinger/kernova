import Foundation
@testable import Kernova

/// In-memory mock for `VMStorageProviding` that tracks operations without touching disk —
/// except `vmsDirectory`/`stagingDirectory`, which import/clone tests need as real, writable
/// directories since `VMCommandCore.importVM(from:)` does a raw `FileManager.copyItem` into the
/// staging area rather than going through this protocol, and `cloneVMBundle`, which creates its
/// destination directory for the same reason (see below). `baseDirectory` is unique per instance
/// (suffixed with a UUID) so parallel/`.serialized` tests copying real bundles into it can't
/// collide or leak state into each other.
///
/// Because `vmsDirectory`/`cloneVMBundle` are real, on-disk paths, and `VMLibraryViewModel.startLibrary()`
/// starts a real `VMDirectoryWatcher` against `vmsDirectory`, a test that calls it and drives an async
/// clone/import to completion should register every other in-memory instance's `bundleURL` in
/// `bundles` too (as the existing clone tests do) — otherwise a watcher-triggered
/// `reconcileWithDisk()` racing the test could mistake an unregistered resting-state instance for a
/// bundle that vanished from disk and evict it.
final class MockVMStorageService: VMStorageProviding, @unchecked Sendable {
    // MARK: - Storage

    var bundles: [URL: VMConfiguration] = [:]
    private let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MockVMs-\(UUID().uuidString)", isDirectory: true)

    deinit {
        // `vmsDirectory` creates `baseDirectory` on every access (see below); reclaim it here so
        // every test — not just the ones that exercise a real copy — doesn't leak a directory
        // into the system temp folder on every run.
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    // MARK: - Call Tracking

    var listVMBundlesCallCount = 0
    var saveConfigurationCallCount = 0
    var deleteVMBundleCallCount = 0
    var permanentlyDeleteVMBundleCallCount = 0
    var createVMBundleCallCount = 0
    var cloneVMBundleCallCount = 0
    var publishBundleCallCount = 0
    var reclaimStagedBundlesCallCount = 0

    /// `listVMBundlesCallCount` as it stood when `reclaimStagedBundles()` last ran,
    /// so a test can prove the reclaim preceded the library read.
    var listVMBundlesCallCountAtReclaim: Int?

    /// The `filesToCopy` argument from the most recent `cloneVMBundle` call.
    var lastCloneFilesToCopy: [String]?

    // MARK: - Error Injection

    var createVMBundleError: (any Error)?
    var cloneVMBundleError: (any Error)?
    var publishBundleError: (any Error)?
    var saveConfigurationError: (any Error)?
    var deleteVMBundleError: (any Error)?
    var permanentlyDeleteVMBundleError: (any Error)?
    var listVMBundlesError: (any Error)?
    /// Set of bundle URLs whose loadConfiguration should throw.
    var loadConfigurationFailURLs: Set<URL> = []

    // MARK: - VMStorageProviding

    var vmsDirectory: URL {
        get throws {
            // Mirrors production `VMStorageService.vmsDirectory`, which creates the directory
            // when missing — `copyItem`'s destination parent must already exist.
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            return baseDirectory
        }
    }

    var stagingDirectory: URL {
        get throws {
            let staging = baseDirectory.appendingPathComponent(".Staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            return staging
        }
    }

    func bundleURL(for configuration: VMConfiguration) throws -> URL {
        baseDirectory.appendingPathComponent(
            "\(configuration.id.uuidString).\(VMStorageService.bundleExtension)",
            isDirectory: true
        )
    }

    func stagedBundleURL(for configuration: VMConfiguration) throws -> URL {
        try stagingDirectory.appendingPathComponent(
            "\(configuration.id.uuidString).\(VMStorageService.bundleExtension)",
            isDirectory: true
        )
    }

    func listVMBundles() throws -> [URL] {
        listVMBundlesCallCount += 1
        if let error = listVMBundlesError { throw error }
        // Mirrors the real service's hidden-skipping enumeration, which never
        // admits a bundle still being written under `.Staging`.
        let staging = (try? stagingDirectory)?.standardizedFileURL
        return bundles.keys.filter {
            $0.deletingLastPathComponent().standardizedFileURL != staging
        }
    }

    func loadConfiguration(from bundleURL: URL) throws -> VMConfiguration {
        if loadConfigurationFailURLs.contains(bundleURL) {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        guard let config = bundles[bundleURL] else {
            throw VMStorageError.bundleNotFound(bundleURL)
        }
        return config
    }

    func saveConfiguration(_ configuration: VMConfiguration, to bundleURL: URL) throws {
        saveConfigurationCallCount += 1
        if let error = saveConfigurationError { throw error }
        bundles[bundleURL] = configuration
    }

    func createVMBundle(_ configuration: VMConfiguration, at bundleURL: URL) throws {
        createVMBundleCallCount += 1
        if let error = createVMBundleError { throw error }
        bundles[bundleURL] = configuration
    }

    func cloneVMBundle(
        from sourceBundleURL: URL, to destinationBundleURL: URL, newConfiguration: VMConfiguration,
        filesToCopy: [String]
    ) throws {
        cloneVMBundleCallCount += 1
        lastCloneFilesToCopy = filesToCopy
        if let error = cloneVMBundleError { throw error }
        // Mirrors the real service actually creating the bundle directory on disk:
        // a macOS clone's `copyWork` writes a regenerated MachineIdentifier file
        // straight into this URL afterward, which needs the directory to exist.
        try FileManager.default.createDirectory(
            at: destinationBundleURL, withIntermediateDirectories: true)
        bundles[destinationBundleURL] = newConfiguration
    }

    /// Renames the staged tree when one is really on disk — clone and import tests
    /// write real files — and re-keys the in-memory entry either way, so an
    /// assertion on `bundles[finalURL]` reads the published bundle.
    func publishBundle(from stagedURL: URL, to bundleURL: URL) throws {
        publishBundleCallCount += 1
        if let error = publishBundleError { throw error }
        let fm = FileManager.default
        if fm.fileExists(atPath: stagedURL.path(percentEncoded: false)) {
            guard !fm.fileExists(atPath: bundleURL.path(percentEncoded: false)) else {
                throw VMStorageError.bundleAlreadyExists(bundleURL)
            }
            try fm.moveItem(at: stagedURL, to: bundleURL)
        }
        if let staged = bundles.removeValue(forKey: stagedURL) {
            bundles[bundleURL] = staged
        }
    }

    func reclaimStagedBundles() {
        reclaimStagedBundlesCallCount += 1
        listVMBundlesCallCountAtReclaim = listVMBundlesCallCount
    }

    func deleteVMBundle(at bundleURL: URL) throws {
        deleteVMBundleCallCount += 1
        if let error = deleteVMBundleError { throw error }
        bundles.removeValue(forKey: bundleURL)
    }

    func permanentlyDeleteVMBundle(at bundleURL: URL) throws {
        permanentlyDeleteVMBundleCallCount += 1
        if let error = permanentlyDeleteVMBundleError { throw error }
        bundles.removeValue(forKey: bundleURL)
    }
}
