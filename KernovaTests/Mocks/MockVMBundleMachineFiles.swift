import Foundation
import KernovaKit

@testable import Kernova

/// Mock for `VMBundleMachineFileWorking` whose snapshot store records file
/// operations without touching disk. The manifest is a bundle state file,
/// seeded through ``MockVMStorageService/files``.
///
/// The suspend slot, the firmware and platform files and the in-bundle disks
/// go to a real ``VMBundleMachineFiles`` trashing through `fileSystem`: every
/// predicate that asks about the slot reads the file, so a removal has to
/// happen for real.
///
/// Lock-based because production reads and writes it from `Task.detached`, so
/// calls arrive off the test's isolation.
final class MockVMBundleMachineFiles: VMBundleMachineFileWorking, @unchecked Sendable {
    /// One call this store answered, in the order a revert makes them.
    enum Event: Equatable {
        case stageRestore
        case installRestore
        case sweepRestoreStaging
    }

    private struct State {
        var events: [Event] = []
        var capturedPaths: [UUID: [String]] = [:]
        var capturedConfigurations: [UUID: VMConfiguration] = [:]
        var discardedIDs: [UUID] = []
        var removedDirectoryIDs: [UUID] = []
        var sweptStagingBundleURLs: [URL] = []
        var sizes: [UUID: SnapshotSize] = [:]
        var sizeReads = 0
        var sizeReadHold: DispatchSemaphore?
        var captureError: (any Error)?
        var stageError: (any Error)?
        var discardError: (any Error)?
        var platformMachineIdentifier: Data?
    }

    private let lock = NSLock()
    private var state = State()

    /// Where a prepared snapshot's own `config.json` is written, as the real
    /// store writes it into the bundle — what the manifest reads each
    /// snapshot's MAC address from. `nil` writes it nowhere.
    private let files: InMemoryVMBundleFiles?

    /// What every operation outside the snapshot store runs through.
    private let real: VMBundleMachineFiles

    init(files: InMemoryVMBundleFiles? = nil, fileSystem: MockFileSystem = MockFileSystem()) {
        self.files = files
        real = VMBundleMachineFiles(fileSystem: fileSystem)
    }

    // MARK: - Seeding

    /// Seeds the size one snapshot reports.
    func setSize(_ size: SnapshotSize, for snapshotID: UUID) {
        lock.withLock { state.sizes[snapshotID] = size }
    }

    /// Seeds the configuration one snapshot captured, as `prepareSnapshot`
    /// records it — what a revert reads back and installs.
    func setCapturedConfiguration(_ configuration: VMConfiguration, for snapshotID: UUID) {
        lock.withLock { state.capturedConfigurations[snapshotID] = configuration }
    }

    // MARK: - Recorded calls

    /// The revert calls this store answered, in order.
    var events: [Event] { lock.withLock { state.events } }
    /// Bundle-relative paths passed to `captureDisks`, keyed by snapshot id.
    var capturedPaths: [UUID: [String]] { lock.withLock { state.capturedPaths } }
    var discardedIDs: [UUID] { lock.withLock { state.discardedIDs } }
    var removedDirectoryIDs: [UUID] { lock.withLock { state.removedDirectoryIDs } }
    var sweptStagingBundleURLs: [URL] { lock.withLock { state.sweptStagingBundleURLs } }

    // MARK: - Error injection

    var captureError: (any Error)? {
        get { lock.withLock { state.captureError } }
        set { lock.withLock { state.captureError = newValue } }
    }
    /// Thrown by the next and every later `stageRestore`.
    var stageError: (any Error)? {
        get { lock.withLock { state.stageError } }
        set { lock.withLock { state.stageError = newValue } }
    }
    var discardError: (any Error)? {
        get { lock.withLock { state.discardError } }
        set { lock.withLock { state.discardError = newValue } }
    }

    /// When set, `createMacPlatformFiles` writes this as the bundle's
    /// `MachineIdentifier` and answers it, decoding no hardware model — which
    /// only a restore image can supply.
    var platformMachineIdentifier: Data? {
        get { lock.withLock { state.platformMachineIdentifier } }
        set { lock.withLock { state.platformMachineIdentifier = newValue } }
    }

    // MARK: - VMBundleMachineFileWorking

    func prepareSnapshot(
        bundleURL: URL, snapshotID: UUID, configuration: VMConfiguration
    ) throws -> VMSnapshotCapturePlan {
        files?.setSnapshotConfiguration(configuration, id: snapshotID, at: bundleURL)
        let layout = VMBundleLayout(bundleURL: bundleURL)
        return lock.withLock {
            state.capturedConfigurations[snapshotID] = configuration
            return VMSnapshotCapturePlan(
                saveFileURL: layout.snapshotLayout(id: snapshotID).saveFileURL,
                relativePaths: VMBundleMachineFiles.capturedRelativePaths(
                    for: configuration, layout: layout))
        }
    }

    func captureDisks(bundleURL: URL, snapshotID: UUID, relativePaths: [String]) throws {
        try lock.withLock {
            if let error = state.captureError { throw error }
            state.capturedPaths[snapshotID] = relativePaths
        }
    }

    func captureSuspendSlot(bundleURL: URL, snapshotID: UUID) throws {
        try lock.withLock {
            if let error = state.captureError { throw error }
        }
    }

    /// Answers the plan for a snapshot this store captured or was seeded with;
    /// a snapshot with no recorded configuration refuses, exactly as a snapshot
    /// directory missing its `config.json` does. The saved state a warm snapshot
    /// also needs has no stand-in here — `VMBundleMachineFilesTests` covers that
    /// check against real files.
    func planRestore(
        bundleURL: URL, snapshotID: UUID, kind: VMSnapshotKind
    ) throws -> VMSnapshotRestorePlan {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        return try lock.withLock {
            guard let configuration = state.capturedConfigurations[snapshotID] else {
                throw VMSnapshotError.snapshotMissingConfiguration
            }
            return VMSnapshotRestorePlan(
                configuration: configuration,
                relativePaths: VMBundleMachineFiles.capturedRelativePaths(
                    for: configuration, layout: layout),
                kind: kind)
        }
    }

    func stageRestore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws {
        try lock.withLock {
            state.events.append(.stageRestore)
            if let error = state.stageError { throw error }
        }
    }

    func installRestore(bundleURL: URL, plan: VMSnapshotRestorePlan) throws {
        lock.withLock { state.events.append(.installRestore) }
    }

    func discardSnapshot(bundleURL: URL, snapshotID: UUID) throws {
        try lock.withLock {
            if let error = state.discardError { throw error }
            state.discardedIDs.append(snapshotID)
        }
    }

    func removeSnapshotDirectory(bundleURL: URL, snapshotID: UUID) {
        lock.withLock { state.removedDirectoryIDs.append(snapshotID) }
    }

    func sweepRestoreStaging(bundleURL: URL) {
        lock.withLock {
            state.events.append(.sweepRestoreStaging)
            state.sweptStagingBundleURLs.append(bundleURL)
        }
    }

    func snapshotSizes(bundleURL: URL, snapshotIDs: [UUID]) -> [UUID: SnapshotSize] {
        let (sizes, hold) = lock.withLock {
            var sizes: [UUID: SnapshotSize] = [:]
            for id in snapshotIDs { sizes[id] = state.sizes[id] ?? SnapshotSize(bytes: 0, privateBytes: nil) }
            state.sizeReads += 1
            let hold = state.sizeReadHold
            state.sizeReadHold = nil
            return (sizes, hold)
        }
        sizeReadEntered.notify()
        hold?.wait()
        return sizes
    }

    /// How many size reads have taken their figures.
    var sizeReads: Int { lock.withLock { state.sizeReads } }

    /// Fires as each size read has taken its figures.
    let sizeReadEntered = AsyncGate()

    /// Holds the next size read, after it has taken its figures, until the
    /// returned semaphore is signalled — so a test can land it after a later one.
    func holdNextSizeRead() -> DispatchSemaphore {
        let hold = DispatchSemaphore(value: 0)
        lock.withLock { state.sizeReadHold = hold }
        return hold
    }

    func removeSaveFile(bundleURL: URL) throws {
        try real.removeSaveFile(bundleURL: bundleURL)
    }

    func ensureEFIVariableStore(bundleURL: URL) throws {
        try real.ensureEFIVariableStore(bundleURL: bundleURL)
    }

    func createMacPlatformFiles(bundleURL: URL, hardwareModel: Data) throws -> Data {
        guard let machineIdentifier = platformMachineIdentifier else {
            return try real.createMacPlatformFiles(bundleURL: bundleURL, hardwareModel: hardwareModel)
        }
        try machineIdentifier.write(to: VMBundleLayout(bundleURL: bundleURL).machineIdentifierURL)
        return machineIdentifier
    }

    func createInternalDisk(
        bundleURL: URL, id: UUID, sizeInGB: Int, diskImages: any DiskImageProviding
    ) async throws -> String {
        try await real.createInternalDisk(
            bundleURL: bundleURL, id: id, sizeInGB: sizeInGB, diskImages: diskImages)
    }

    func trashInternalDisk(bundleURL: URL, relativePath: String) throws {
        try real.trashInternalDisk(bundleURL: bundleURL, relativePath: relativePath)
    }
}
