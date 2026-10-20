import Foundation
import KernovaKit
import Synchronization

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

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
final class MockVMStorageService: VMStorageProviding {
    private struct State {
        var listVMBundlesCallCount = 0
        var deleteVMBundleCallCount = 0
        var permanentlyDeleteVMBundleCallCount = 0
        var createVMBundleCallCount = 0
        var cloneVMBundleCallCount = 0
        var publishBundleCallCount = 0
        var reclaimStagedBundlesCallCount = 0
        var discardedStagedURLs: [URL] = []
        var stagedBundleURLs: [URL] = []
        var lastCloneRelativePaths: [String]?
        var createVMBundleError: (any Error)?
        var cloneVMBundleError: (any Error)?
        var publishBundleError: (any Error)?
        var discardStagedBundleError: (any Error)?
        var deleteVMBundleError: (any Error)?
        var listVMBundlesError: (any Error)?
        var afterPublish: (@MainActor () -> Void)?
        var publishHold: DispatchSemaphore?
        var cloneHold: DispatchSemaphore?
    }

    private let state = Mutex(State())

    // MARK: - Storage

    /// Every bundle's state files. A bundle it holds nothing for is read and
    /// written on disk, so a bundle `importVM` really copies arrives with what
    /// its source held.
    let files = InMemoryVMBundleFiles()

    var bundleFiles: any VMBundleFileAccessing { files }

    /// Each bundle's `config.json`, read from one ``InMemoryVMBundleFiles/snapshot()``.
    var bundles: [URL: VMConfiguration] {
        let snapshot = files.snapshot()
        return Dictionary(
            uniqueKeysWithValues: snapshot.bundleURLs.compactMap { url in
                snapshot.configuration(at: url).map { (url, $0) }
            })
    }

    /// Each bundle's `host-state.json`, read from one ``InMemoryVMBundleFiles/snapshot()``.
    var hostStates: [URL: VMHostState] {
        let snapshot = files.snapshot()
        return Dictionary(
            uniqueKeysWithValues: snapshot.bundleURLs.compactMap { url in
                snapshot.hostState(at: url).map { (url, $0) }
            })
    }

    /// Seeds the bundle at `url` with `configuration` as its `config.json`.
    func setConfiguration(_ configuration: VMConfiguration, at url: URL) {
        files.setConfiguration(configuration, at: url)
    }

    /// Seeds the bundle at `url` with `hostState` as its `host-state.json`.
    func setHostState(_ hostState: VMHostState, at url: URL) {
        files.setHostState(hostState, at: url)
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

    var listVMBundlesCallCount: Int { state.withLock { $0.listVMBundlesCallCount } }
    /// Replaces of `config.json` that landed, in any bundle.
    var saveConfigurationCallCount: Int { files.replaceCount(of: VMBundleLayout.configRelativePath) }
    /// Replaces of `host-state.json` that landed, in any bundle.
    var saveHostStateCallCount: Int { files.replaceCount(of: VMBundleLayout.hostStateRelativePath) }
    var deleteVMBundleCallCount: Int { state.withLock { $0.deleteVMBundleCallCount } }
    var permanentlyDeleteVMBundleCallCount: Int { state.withLock { $0.permanentlyDeleteVMBundleCallCount } }
    var createVMBundleCallCount: Int { state.withLock { $0.createVMBundleCallCount } }
    var cloneVMBundleCallCount: Int { state.withLock { $0.cloneVMBundleCallCount } }
    var publishBundleCallCount: Int { state.withLock { $0.publishBundleCallCount } }
    var reclaimStagedBundlesCallCount: Int { state.withLock { $0.reclaimStagedBundlesCallCount } }

    /// Every staged tree discarded, in order, whether or not the discard
    /// threw.
    var discardedStagedURLs: [URL] { state.withLock { $0.discardedStagedURLs } }

    /// Every staged path handed out, in order — the only way a test can name one,
    /// since each is minted fresh rather than derived from a configuration.
    var stagedBundleURLs: [URL] { state.withLock { $0.stagedBundleURLs } }

    /// The `relativePaths` argument from the most recent `cloneVMBundle` call.
    var lastCloneRelativePaths: [String]? { state.withLock { $0.lastCloneRelativePaths } }

    // MARK: - Error Injection

    /// Each sets the error every later call of its operation throws; `nil`
    /// clears it.
    func setCreateVMBundleError(_ error: (any Error)?) {
        state.withLock { $0.createVMBundleError = error }
    }

    func setCloneVMBundleError(_ error: (any Error)?) {
        state.withLock { $0.cloneVMBundleError = error }
    }

    func setPublishBundleError(_ error: (any Error)?) {
        state.withLock { $0.publishBundleError = error }
    }

    func setDiscardStagedBundleError(_ error: (any Error)?) {
        state.withLock { $0.discardStagedBundleError = error }
    }

    func setDeleteVMBundleError(_ error: (any Error)?) {
        state.withLock { $0.deleteVMBundleError = error }
    }

    func setListVMBundlesError(_ error: (any Error)?) {
        state.withLock { $0.listVMBundlesError = error }
    }

    /// Thrown by every later replace of `config.json`.
    func setSaveConfigurationError(_ error: (any Error)?) {
        files.setReplaceError(error, for: VMBundleLayout.configRelativePath)
    }

    /// Thrown by every later replace of `host-state.json`.
    func setSaveHostStateError(_ error: (any Error)?) {
        files.setReplaceError(error, for: VMBundleLayout.hostStateRelativePath)
    }

    /// Makes the bundle's `config.json` read as present but unreadable, or
    /// readable again.
    func setConfigurationUnreadable(_ isUnreadable: Bool, at bundleURL: URL) {
        files.setUnreadable(isUnreadable, relativePath: VMBundleLayout.configRelativePath, at: bundleURL)
    }

    /// Makes the bundle's `host-state.json` read as present but unreadable, or
    /// readable again.
    func setHostStateUnreadable(_ isUnreadable: Bool, at bundleURL: URL) {
        files.setUnreadable(isUnreadable, relativePath: VMBundleLayout.hostStateRelativePath, at: bundleURL)
    }

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
        state.withLock { $0.afterPublish = hook }
        defer { state.withLock { $0.afterPublish = nil } }
        return try await body()
    }

    /// Holds every later publish on its own thread, after its rename has
    /// landed, until `hold` is signalled — the arrival stays past the point a
    /// cancel stops it while the main actor is free. ``publishLanded`` fires as
    /// the hold begins.
    func setPublishHold(_ hold: DispatchSemaphore?) {
        state.withLock { $0.publishHold = hold }
    }

    let publishLanded = AsyncGate()

    /// Holds every later clone's copy on its own thread, before it writes
    /// anything, until `hold` is signalled; ``cloneEntered`` fires as the hold
    /// begins. An error set while held is the one the copy throws.
    func setCloneHold(_ hold: DispatchSemaphore?) {
        state.withLock { $0.cloneHold = hold }
    }

    let cloneEntered = AsyncGate()

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
        state.withLock { $0.stagedBundleURLs.append(url) }
        return url
    }

    func listVMBundles() throws -> [URL] {
        try state.withLock { state in
            state.listVMBundlesCallCount += 1
            if let error = state.listVMBundlesError { throw error }
        }
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
        try state.withLock { state in
            state.createVMBundleCallCount += 1
            if let error = state.createVMBundleError { throw error }
        }
        files.setData(nil, atRelativePath: VMBundleLayout.configRelativePath, in: bundleURL)
    }

    func cloneVMBundle(from sourceBundleURL: URL, to destinationBundleURL: URL, relativePaths: [String])
        throws
    {
        let cloneHold = state.withLock { state in
            state.cloneVMBundleCallCount += 1
            state.lastCloneRelativePaths = relativePaths
            return state.cloneHold
        }
        if let cloneHold {
            cloneEntered.notify()
            cloneHold.wait()
        }
        if let error = state.withLock({ $0.cloneVMBundleError }) { throw error }
        // Mirrors the real service on disk: a macOS clone's `copyOut` writes
        // its MachineIdentifier file straight into this URL afterward, and a
        // test that lays real files into the source reads them in the clone.
        try FileManager.default.createDirectory(
            at: destinationBundleURL, withIntermediateDirectories: true)
        try VMBundleItems.copyItems(
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
        try state.withLock { state in
            state.publishBundleCallCount += 1
            if let error = state.publishBundleError { throw error }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: stagedURL.path(percentEncoded: false)) {
            guard !fm.fileExists(atPath: bundleURL.path(percentEncoded: false)) else {
                throw VMStorageError.bundleAlreadyExists(bundleURL)
            }
            try fm.moveItem(at: stagedURL, to: bundleURL)
        }
        files.moveBundle(from: stagedURL, to: bundleURL)
        if let publishHold = state.withLock({ $0.publishHold }) {
            publishLanded.notify()
            publishHold.wait()
        }
        if let afterPublish = state.withLock({ $0.afterPublish }) {
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
        try state.withLock { state in
            state.discardedStagedURLs.append(stagedURL)
            if let error = state.discardStagedBundleError { throw error }
        }
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
        state.withLock { $0.reclaimStagedBundlesCallCount += 1 }
        return Task {}
    }

    func deleteVMBundle(at bundleURL: URL) throws {
        try state.withLock { state in
            state.deleteVMBundleCallCount += 1
            if let error = state.deleteVMBundleError { throw error }
        }
        files.removeBundle(at: bundleURL)
    }

    func permanentlyDeleteVMBundle(at bundleURL: URL) throws {
        state.withLock { $0.permanentlyDeleteVMBundleCallCount += 1 }
        files.removeBundle(at: bundleURL)
    }
}
