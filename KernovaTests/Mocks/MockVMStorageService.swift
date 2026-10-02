import Foundation
import KernovaKit
import KernovaTestSupport
@testable import Kernova

/// In-memory mock for `VMStorageProviding` that tracks operations without touching disk —
/// except `vmsDirectory`/`stagingRoot`, which import/clone tests need as real, writable
/// directories since `VMCommandCore.importVM(from:)` does a raw `FileManager.copyItem` into the
/// staging area rather than going through this protocol, and `cloneVMBundle`, which creates its
/// destination directory for the same reason (see below). `baseDirectory` is a
/// `TestScratchDirectory` per instance, so tests copying real bundles into it can't collide or
/// leak state into each other.
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
    private let scratch: TestScratchDirectory
    private var baseDirectory: URL { scratch.url }

    /// Where staged paths are minted, as the real service's root sits under the
    /// VMs directory's `.Staging`.
    private let stagingRoot: ProcessStagingRoot

    init() {
        let scratch = TestScratchDirectory(prefix: "MockVMs")
        self.scratch = scratch
        stagingRoot = ProcessStagingRoot(
            parent: scratch.url.appendingPathComponent(".Staging", isDirectory: true))
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

    /// Every staged tree discarded, in order, whether or not the discard
    /// threw.
    var discardedStagedURLs: [URL] = []

    /// Every staged path handed out, in order — the only way a test can name one,
    /// since each is minted fresh rather than derived from a configuration.
    var stagedBundleURLs: [URL] = []

    /// The `relativePaths` argument from the most recent `cloneVMBundle` call.
    var lastCloneRelativePaths: [String]?

    // MARK: - Error Injection

    var createVMBundleError: (any Error)?
    var cloneVMBundleError: (any Error)?
    var publishBundleError: (any Error)?
    var discardStagedBundleError: (any Error)?

    private var afterPublish: (@MainActor () -> Void)?

    // periphery:ignore:parameters isolation - `isolated` keeps `body` on the caller's actor
    /// Runs `body` with `hook` installed to run on the main actor once each
    /// publish's rename has landed and before the publishing arrival resumes —
    /// the window between the rename and the arrival's adoption. The publish
    /// runs detached while the main actor waits on it, so the hop cannot
    /// deadlock.
    ///
    /// The hook is gone once `body` ends, so one capturing the library that
    /// owns this store keeps neither alive past it.
    func withAfterPublish<Value>(
        _ hook: @escaping @MainActor () -> Void,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        afterPublish = hook
        defer { afterPublish = nil }
        return try await body()
    }

    /// Holds a publish on its own thread, after its rename has landed, until
    /// signalled — the arrival stays past the point a cancel stops it while the
    /// main actor is free. ``publishLanded`` fires as the hold begins.
    var publishHold: DispatchSemaphore?
    let publishLanded = AsyncGate()

    /// Holds a clone's copy on its own thread, before it writes anything,
    /// until signalled; ``cloneEntered`` fires as the hold begins. An error set
    /// while held is the one the copy throws.
    var cloneHold: DispatchSemaphore?
    let cloneEntered = AsyncGate()
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

    func bundleURL(for configuration: VMConfiguration) throws -> URL {
        baseDirectory.appendingPathComponent(
            "\(configuration.id.uuidString).\(VMBundleFormat.fileExtension)",
            isDirectory: true
        )
    }

    func makeStagedBundleURL() throws -> URL {
        try stagingRoot.claim()
        let url = stagingRoot.url.appendingPathComponent(
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
        let staging = stagingRoot.url.standardizedFileURL
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

    func cloneVMBundle(from sourceBundleURL: URL, to destinationBundleURL: URL, relativePaths: [String])
        throws
    {
        cloneVMBundleCallCount += 1
        lastCloneRelativePaths = relativePaths
        if let cloneHold {
            cloneEntered.notify()
            cloneHold.wait()
        }
        if let error = cloneVMBundleError { throw error }
        // Mirrors the real service on disk: a macOS clone's `copyOut` writes
        // its MachineIdentifier file straight into this URL afterward, and a
        // test that lays real files into the source reads them in the clone.
        try FileManager.default.createDirectory(
            at: destinationBundleURL, withIntermediateDirectories: true)
        try VMBundleMachineFiles.copyItems(
            relativePaths, from: sourceBundleURL, to: destinationBundleURL, ifMissing: .skip)
        // The same paths among the files this store holds — a snapshot's own
        // configuration above all, which the copy's manifest is read back from.
        files.copyFiles(relativePaths, from: sourceBundleURL, to: destinationBundleURL)
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
        if let publishHold {
            publishLanded.notify()
            publishHold.wait()
        }
        if let afterPublish {
            DispatchQueue.main.sync { MainActor.assumeIsolated { afterPublish() } }
        }
    }

    /// A bundle the store holds is identified as the default case-insensitive
    /// volume would identify it — every spelling it folds together names that
    /// one bundle; any other is identified on disk, as a real copy is.
    func bundleIdentity(at bundleURL: URL) -> VMBundleIdentity? {
        let key = VMBundleIdentity.nameKey(bundleURL)
        let held = files.bundleURLs.contains {
            VMBundleIdentity.nameKey($0) == key
                && files.data(atRelativePath: VMBundleLayout.configRelativePath, in: $0) != nil
        }
        return held
            ? VMBundleIdentity(fileResourceIdentifier: key as NSString)
            : VMBundleIdentity(bundleAt: bundleURL)
    }

    func discardStagedBundle(at stagedURL: URL) throws {
        discardedStagedURLs.append(stagedURL)
        if let error = discardStagedBundleError { throw error }
        try? FileManager.default.removeItem(at: stagedURL)
        files.removeBundle(at: stagedURL)
    }

    /// Moves a bundle within the store, as the Finder moving it inside the VMs
    /// directory would.
    func moveBundle(from source: URL, to destination: URL) {
        files.moveBundle(from: source, to: destination)
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
