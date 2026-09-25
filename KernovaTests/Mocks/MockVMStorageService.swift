import Foundation
import KernovaKit
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

    /// Every bundle's state files. A bundle it holds nothing for is read and
    /// written on disk, so a bundle `importVM` really copies arrives with what
    /// its source held.
    let files = InMemoryVMBundleFiles()

    var bundleFiles: any VMBundleFileAccessing { files }

    /// Each bundle's `config.json`, as a view over ``files``: setting an entry
    /// seeds the file, and dropping one drops the bundle.
    var bundles: [URL: VMConfiguration] {
        get {
            Dictionary(
                uniqueKeysWithValues: files.bundleURLs.compactMap { url in
                    files.configuration(at: url).map { (url, $0) }
                })
        }
        set {
            let old = bundles
            for url in old.keys where newValue[url] == nil { files.removeBundle(at: url) }
            for (url, config) in newValue where old[url] != config {
                files.setConfiguration(config, at: url)
            }
        }
    }

    /// Each bundle's `host-state.json`, as a view over ``files``.
    var hostStates: [URL: VMHostState] {
        get {
            Dictionary(
                uniqueKeysWithValues: files.bundleURLs.compactMap { url in
                    files.hostState(at: url).map { (url, $0) }
                })
        }
        set {
            for (url, hostState) in newValue where files.hostState(at: url) != hostState {
                files.setHostState(hostState, at: url)
            }
        }
    }
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
    /// Replaces of `config.json` that landed, in any bundle.
    var saveConfigurationCallCount: Int { files.replaceCount(of: VMBundleLayout.configRelativePath) }
    /// Replaces of `host-state.json` that landed, in any bundle.
    var saveHostStateCallCount: Int { files.replaceCount(of: VMBundleLayout.hostStateRelativePath) }
    var deleteVMBundleCallCount = 0
    var permanentlyDeleteVMBundleCallCount = 0
    var createVMBundleCallCount = 0
    var cloneVMBundleCallCount = 0
    var publishBundleCallCount = 0
    var reclaimStagedBundlesCallCount = 0

    /// Every staged path handed out, in order — the only way a test can name one,
    /// since each is minted fresh rather than derived from a configuration.
    var stagedBundleURLs: [URL] = []

    /// The `filesToCopy` argument from the most recent `cloneVMBundle` call.
    var lastCloneFilesToCopy: [String]?

    // MARK: - Error Injection

    var createVMBundleError: (any Error)?
    var cloneVMBundleError: (any Error)?
    var publishBundleError: (any Error)?
    /// Thrown by every later replace of `config.json`.
    var saveConfigurationError: (any Error)? {
        get { files.replaceError(for: VMBundleLayout.configRelativePath) }
        set { files.setReplaceError(newValue, for: VMBundleLayout.configRelativePath) }
    }
    /// Thrown by every later replace of `host-state.json`.
    var saveHostStateError: (any Error)? {
        get { files.replaceError(for: VMBundleLayout.hostStateRelativePath) }
        set { files.setReplaceError(newValue, for: VMBundleLayout.hostStateRelativePath) }
    }
    var deleteVMBundleError: (any Error)?
    var permanentlyDeleteVMBundleError: (any Error)?
    var listVMBundlesError: (any Error)?
    /// Bundle URLs whose `config.json` reads as present but unreadable.
    var loadConfigurationFailURLs: Set<URL> = [] {
        didSet { markUnreadable(VMBundleLayout.configRelativePath, old: oldValue, new: loadConfigurationFailURLs) }
    }
    /// Bundle URLs whose `host-state.json` reads as present but unreadable.
    var loadHostStateFailURLs: Set<URL> = [] {
        didSet { markUnreadable(VMBundleLayout.hostStateRelativePath, old: oldValue, new: loadHostStateFailURLs) }
    }

    private func markUnreadable(_ relativePath: String, old: Set<URL>, new: Set<URL>) {
        for url in old.subtracting(new) { files.setUnreadable(false, relativePath: relativePath, at: url) }
        for url in new.subtracting(old) { files.setUnreadable(true, relativePath: relativePath, at: url) }
    }

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
            "\(configuration.id.uuidString).\(VMBundleFormat.fileExtension)",
            isDirectory: true
        )
    }

    func makeStagedBundleURL() throws -> URL {
        let url = try stagingDirectory.appendingPathComponent(
            "\(UUID().uuidString).\(VMBundleFormat.fileExtension)",
            isDirectory: true
        )
        stagedBundleURLs.append(url)
        return url
    }

    func listVMBundles() throws -> [URL] {
        listVMBundlesCallCount += 1
        if let error = listVMBundlesError { throw error }
        // Mirrors the real service's hidden-skipping enumeration, which never
        // admits a bundle still being written under `.Staging`.
        let staging = (try? stagingDirectory)?.standardizedFileURL
        return files.bundleURLs.filter {
            files.data(atRelativePath: VMBundleLayout.configRelativePath, in: $0) != nil
                && $0.deletingLastPathComponent().standardizedFileURL != staging
        }
    }

    /// Records the directory as held, so the configuration the create writes
    /// next lands in ``files`` rather than on disk.
    func createVMBundle(at bundleURL: URL) throws {
        createVMBundleCallCount += 1
        if let error = createVMBundleError { throw error }
        files.setData(nil, atRelativePath: VMBundleLayout.configRelativePath, in: bundleURL)
    }

    func cloneVMBundle(from sourceBundleURL: URL, to destinationBundleURL: URL, filesToCopy: [String])
        throws
    {
        cloneVMBundleCallCount += 1
        lastCloneFilesToCopy = filesToCopy
        if let error = cloneVMBundleError { throw error }
        // Mirrors the real service actually creating the bundle directory on disk:
        // a macOS clone's `copyWork` writes a regenerated MachineIdentifier file
        // straight into this URL afterward, which needs the directory to exist.
        try FileManager.default.createDirectory(
            at: destinationBundleURL, withIntermediateDirectories: true)
        files.setData(nil, atRelativePath: VMBundleLayout.configRelativePath, in: destinationBundleURL)
    }

    /// Renames the staged tree when one is really on disk — clone and import tests
    /// write real files — and re-keys the in-memory files either way, so an
    /// assertion on `bundles[finalURL]` or `hostStates[finalURL]` reads the
    /// published bundle.
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
        files.moveBundle(from: stagedURL, to: bundleURL)
    }

    @discardableResult
    func reclaimStagedBundles() -> Task<Void, Never> {
        reclaimStagedBundlesCallCount += 1
        return Task {}
    }

    func deleteVMBundle(at bundleURL: URL) throws {
        deleteVMBundleCallCount += 1
        if let error = deleteVMBundleError { throw error }
        files.removeBundle(at: bundleURL)
    }

    func permanentlyDeleteVMBundle(at bundleURL: URL) throws {
        permanentlyDeleteVMBundleCallCount += 1
        if let error = permanentlyDeleteVMBundleError { throw error }
        files.removeBundle(at: bundleURL)
    }
}
