import Foundation
import KernovaKit
import Synchronization

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

/// Mock for `VMBundleMachineFileWorking` whose snapshot store records file
/// operations without touching disk. The manifest is a bundle state file,
/// seeded through ``MockVMStorageService/files``.
///
/// The suspend slot, the firmware and platform files and the in-bundle disks
/// go to a real ``VMBundleMachineFiles`` trashing through `fileSystem` and
/// writing platform files through `platform`: every predicate that asks about
/// the slot reads the file, so a removal has to happen for real.
///
/// Lock-based because production reads and writes it from `Task.detached`, so
/// calls arrive off the test's isolation.
final class MockVMBundleMachineFiles: VMBundleMachineFileWorking {
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
        var diskSizes: [UUID: VMBundleLayout.DiskSizes] = [:]
        var sizeReads = 0
        var sizeReadHold: DispatchSemaphore?
        var captureError: (any Error)?
        var stageError: (any Error)?
        var discardError: (any Error)?
        var platformMachineIdentifier: Data?
    }

    private let state = Mutex(State())

    /// Where a prepared snapshot's own `config.json` is written, as the real
    /// store writes it into the bundle — what the manifest reads each
    /// snapshot's MAC address from. `nil` writes it nowhere.
    private let files: InMemoryVMBundleFiles?

    /// What every operation outside the snapshot store runs through.
    private let real: VMBundleMachineFiles

    init(
        files: InMemoryVMBundleFiles? = nil, fileSystem: MockFileSystem = MockFileSystem(),
        platform: any VMPlatformFileWriting = FakePlatformFiles()
    ) {
        self.files = files
        real = VMBundleMachineFiles(fileSystem: fileSystem, platform: platform)
    }

    // MARK: - Seeding

    /// Seeds the size one snapshot reports.
    func setSize(_ size: SnapshotSize, for snapshotID: UUID) {
        state.withLock { $0.sizes[snapshotID] = size }
    }

    /// Seeds the figures one disk image reports; an image not seeded reads
    /// as unreadable.
    func setDiskSizes(_ sizes: VMBundleLayout.DiskSizes, for imageID: UUID) {
        state.withLock { $0.diskSizes[imageID] = sizes }
    }

    /// Seeds the configuration one snapshot captured, as `prepareSnapshot`
    /// records it — what a revert reads back and installs.
    func setCapturedConfiguration(_ configuration: VMConfiguration, for snapshotID: UUID) {
        state.withLock { $0.capturedConfigurations[snapshotID] = configuration }
    }

    // MARK: - Recorded calls

    /// The revert calls this store answered, in order.
    var events: [Event] { state.withLock { $0.events } }
    /// Bundle-relative paths passed to `captureDisks`, keyed by snapshot id.
    var capturedPaths: [UUID: [String]] { state.withLock { $0.capturedPaths } }
    var discardedIDs: [UUID] { state.withLock { $0.discardedIDs } }
    var removedDirectoryIDs: [UUID] { state.withLock { $0.removedDirectoryIDs } }
    var sweptStagingBundleURLs: [URL] { state.withLock { $0.sweptStagingBundleURLs } }

    // MARK: - Error injection

    /// Sets the error every later disk or suspend-slot capture throws.
    func setCaptureError(_ error: (any Error)?) {
        state.withLock { $0.captureError = error }
    }

    /// Sets the error the next and every later `stageRestore` throws.
    func setStageError(_ error: (any Error)?) {
        state.withLock { $0.stageError = error }
    }

    /// Sets the error every later `discardSnapshot` throws.
    func setDiscardError(_ error: (any Error)?) {
        state.withLock { $0.discardError = error }
    }

    /// Once set, `createMacPlatformFiles` writes `identifier` as the bundle's
    /// `MachineIdentifier` and answers it, decoding no hardware model — which
    /// only a restore image can supply.
    func setPlatformMachineIdentifier(_ identifier: Data?) {
        state.withLock { $0.platformMachineIdentifier = identifier }
    }

    // MARK: - VMBundleMachineFileWorking

    func prepareSnapshot(
        bundleURL: URL, snapshotID: UUID, configuration: VMConfiguration
    ) throws -> VMSnapshotCapturePlan {
        files?.setSnapshotConfiguration(configuration, id: snapshotID, at: bundleURL)
        let layout = VMBundleLayout(bundleURL: bundleURL)
        return state.withLock { state in
            state.capturedConfigurations[snapshotID] = configuration
            return VMSnapshotCapturePlan(
                saveFileURL: layout.snapshotLayout(id: snapshotID).saveFileURL,
                relativePaths: VMBundleItems.capturedRelativePaths(
                    for: configuration, layout: layout))
        }
    }

    func captureDisks(bundleURL: URL, snapshotID: UUID, relativePaths: [String]) throws {
        try state.withLock { state in
            if let error = state.captureError { throw error }
            state.capturedPaths[snapshotID] = relativePaths
        }
    }

    func captureSuspendSlot(bundleURL: URL, snapshotID: UUID) throws {
        try state.withLock { state in
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
        return try state.withLock { state in
            guard let configuration = state.capturedConfigurations[snapshotID] else {
                throw VMSnapshotError.snapshotMissingConfiguration
            }
            return VMSnapshotRestorePlan(
                configuration: configuration,
                relativePaths: VMBundleItems.capturedRelativePaths(
                    for: configuration, layout: layout),
                kind: kind)
        }
    }

    func stageRestore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws {
        try state.withLock { state in
            state.events.append(.stageRestore)
            if let error = state.stageError { throw error }
        }
    }

    func installRestore(bundleURL: URL, plan: VMSnapshotRestorePlan) throws {
        state.withLock { $0.events.append(.installRestore) }
    }

    func discardSnapshot(bundleURL: URL, snapshotID: UUID) throws {
        try state.withLock { state in
            if let error = state.discardError { throw error }
            state.discardedIDs.append(snapshotID)
        }
    }

    func removeSnapshotDirectory(bundleURL: URL, snapshotID: UUID) {
        state.withLock { $0.removedDirectoryIDs.append(snapshotID) }
    }

    func sweepRestoreStaging(bundleURL: URL) {
        state.withLock { state in
            state.events.append(.sweepRestoreStaging)
            state.sweptStagingBundleURLs.append(bundleURL)
        }
    }

    func snapshotSizes(bundleURL: URL, snapshotIDs: [UUID]) -> [UUID: SnapshotSize] {
        let (sizes, hold) = state.withLock { state in
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

    func diskSizes(
        bundleURL: URL, images: [UUID: DiskImageReference]
    ) -> [UUID: VMBundleLayout.DiskSizes] {
        state.withLock { state in
            Dictionary(
                uniqueKeysWithValues: images.keys.map { ($0, state.diskSizes[$0] ?? VMBundleLayout.DiskSizes()) })
        }
    }

    /// How many size reads have taken their figures.
    var sizeReads: Int { state.withLock { $0.sizeReads } }

    /// Fires as each size read has taken its figures.
    let sizeReadEntered = AsyncGate()

    /// Holds the next size read, after it has taken its figures, until the
    /// returned semaphore is signalled — so a test can land it after a later one.
    func holdNextSizeRead() -> DispatchSemaphore {
        let hold = DispatchSemaphore(value: 0)
        state.withLock { $0.sizeReadHold = hold }
        return hold
    }

    func removeSaveFile(bundleURL: URL) throws {
        try real.removeSaveFile(bundleURL: bundleURL)
    }

    func ensureEFIVariableStore(bundleURL: URL) throws {
        try real.ensureEFIVariableStore(bundleURL: bundleURL)
    }

    func createMacPlatformFiles(bundleURL: URL, hardwareModel: Data) throws -> Data {
        guard let machineIdentifier = state.withLock({ $0.platformMachineIdentifier }) else {
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
