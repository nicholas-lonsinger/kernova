import Foundation
@testable import Kernova

/// In-memory mock for `VMStorageProviding` that tracks operations without touching disk —
/// except `vmsDirectory`, which import/clone tests need as a real, writable directory since
/// `VMLibraryViewModel.reserveAndImport(from:)` does a raw `FileManager.copyItem` into it rather than
/// going through this protocol, and `cloneVMBundle`, which creates its returned URL for the same
/// reason (see below). `baseDirectory` is unique per instance (suffixed with a UUID) so
/// parallel/`.serialized` tests copying real bundles into it can't collide or leak state into
/// each other.
///
/// Because `vmsDirectory`/`cloneVMBundle` are real, on-disk paths, and every `VMLibraryViewModel`
/// starts a real `VMDirectoryWatcher` against `vmsDirectory` in `init`, a test driving an async
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

    var saveConfigurationCallCount = 0
    var deleteVMBundleCallCount = 0
    var permanentlyDeleteVMBundleCallCount = 0
    var createVMBundleCallCount = 0
    var cloneVMBundleCallCount = 0

    // MARK: - Error Injection

    var createVMBundleError: (any Error)?
    var cloneVMBundleError: (any Error)?
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

    func bundleURL(for configuration: VMConfiguration) throws -> URL {
        baseDirectory.appendingPathComponent(
            "\(configuration.id.uuidString).\(VMStorageService.bundleExtension)",
            isDirectory: true
        )
    }

    func listVMBundles() throws -> [URL] {
        if let error = listVMBundlesError { throw error }
        return Array(bundles.keys)
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

    func createVMBundle(for configuration: VMConfiguration) throws -> URL {
        createVMBundleCallCount += 1
        if let error = createVMBundleError { throw error }
        let url = try bundleURL(for: configuration)
        bundles[url] = configuration
        return url
    }

    func cloneVMBundle(from sourceBundleURL: URL, newConfiguration: VMConfiguration, filesToCopy: [String]) throws
        -> URL
    {
        cloneVMBundleCallCount += 1
        if let error = cloneVMBundleError { throw error }
        let url = try bundleURL(for: newConfiguration)
        // Mirrors the real service actually creating the bundle directory on disk:
        // a macOS clone's `copyWork` writes a regenerated MachineIdentifier file
        // straight into this URL afterward, which needs the directory to exist.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        bundles[url] = newConfiguration
        return url
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
