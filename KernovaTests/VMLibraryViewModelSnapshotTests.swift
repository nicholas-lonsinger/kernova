import Foundation
import Testing

@testable import Kernova

@Suite("VMLibraryViewModel Snapshot Tests", .serialized, .admissionGated)
@MainActor
struct VMLibraryViewModelSnapshotTests {
    private let presenter = MockVMLibraryPresenting()
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.snapshots")

    private struct Harness {
        let viewModel: VMLibraryViewModel
        let storage: MockVMStorageService
        let virtualization: MockVirtualizationService
        let snapshots: MockVMSnapshotStore
    }

    private func makeHarness() -> Harness {
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
        let snapshots = MockVMSnapshotStore()
        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            snapshotStore: snapshots,
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            fileSystem: MockFileSystem(),
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider()
        )
        viewModel.presenter = presenter
        return Harness(
            viewModel: viewModel, storage: storage, virtualization: virtualization,
            snapshots: snapshots)
    }

    private func makeInstance(status: VMStatus = .running) -> VMInstance {
        let config = VMConfiguration(name: "Snapshot VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        return VMInstance(
            configuration: config, bundleURL: bundleURL, status: status, preferences: preferences)
    }

    private func makeSnapshot(name: String = "Before the update") -> VMSnapshot {
        VMSnapshot(name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Lists `snapshots` on `instance` and records what each captured, so a
    /// revert finds the configuration a real snapshot directory would hold.
    private func seed(
        _ harness: Harness, _ instance: VMInstance, _ snapshots: [VMSnapshot],
        currentID: UUID? = nil, capturedConfiguration: VMConfiguration? = nil
    ) {
        instance.snapshotManifest = VMSnapshotManifest(snapshots: snapshots, currentID: currentID)
        for snapshot in snapshots {
            harness.snapshots.setCapturedConfiguration(
                capturedConfiguration ?? instance.configuration, for: snapshot.id)
        }
    }

    // MARK: - Seeding

    @Test("A loaded VM carries the snapshots its bundle holds")
    func loadSeedsTheManifest() async throws {
        let harness = makeHarness()
        let config = VMConfiguration(name: "Seeded", guestOS: .linux, bootMode: .efi)
        let bundleURL = try harness.storage.bundleURL(for: config)
        harness.storage.bundles[bundleURL] = config
        let snapshot = makeSnapshot()
        harness.snapshots.setManifest(
            VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id), for: bundleURL)

        await harness.viewModel.loadVMs()

        #expect(harness.viewModel.instances.first?.snapshotManifest.snapshots == [snapshot])
        #expect(harness.viewModel.instances.first?.snapshotManifest.currentID == snapshot.id)
    }

    @Test("Loading a VM reclaims the staging directory an interrupted revert left behind")
    func loadSweepsRevertStaging() async throws {
        let harness = makeHarness()
        let config = VMConfiguration(name: "Interrupted", guestOS: .linux, bootMode: .efi)
        let bundleURL = try harness.storage.bundleURL(for: config)
        harness.storage.bundles[bundleURL] = config

        await harness.viewModel.loadVMs()

        // Otherwise the reclaim waits on the next revert of this same VM, which
        // may never come — and its clones own their blocks outright once the
        // snapshot they were cloned from is discarded.
        #expect(harness.snapshots.sweptStagingBundleURLs == [bundleURL])
    }

    // MARK: - Take

    @Test("Requesting a snapshot opens the sheet")
    func requestOpensTheSheet() {
        let harness = makeHarness()
        let instance = makeInstance()

        harness.viewModel.requestTakeSnapshot(instance)

        #expect(presenter.takeSnapshotSheetInstances.count == 1)
    }

    @Test("A VM with nothing settled to capture opens no sheet")
    func requestRefusedWhileTransitioning() {
        let harness = makeHarness()
        let instance = makeInstance(status: .starting)

        harness.viewModel.requestTakeSnapshot(instance)

        #expect(presenter.takeSnapshotSheetInstances.isEmpty)
    }

    @Test("A capture of a stopped VM is stamped as disks-only")
    func stoppedCaptureIsCold() async {
        let harness = makeHarness()
        let instance = makeInstance(status: .stopped)

        await harness.viewModel.takeSnapshot(instance, name: "Before first boot").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.cold])
        #expect(instance.snapshotManifest.snapshots.map(\.kind) == [.cold])
        #expect(harness.snapshots.manifest(for: instance.bundleURL) == instance.snapshotManifest)
    }

    @Test("A capture of a cold-paused VM is stamped as memory-and-disks and lands in the manifest")
    func coldPausedCaptureIsWarm() async throws {
        let harness = makeHarness()
        let instance = makeInstance(status: .paused)
        // A capturable suspend slot: `canTakeSnapshot` for a cold-paused VM
        // needs one on disk, not just the status.
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        FileManager.default.createFile(
            atPath: instance.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))

        await harness.viewModel.takeSnapshot(instance, name: "Suspended").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.warm])
        #expect(instance.snapshotManifest.snapshots.map(\.kind) == [.warm])
        #expect(harness.snapshots.manifest(for: instance.bundleURL) == instance.snapshotManifest)
    }

    @Test("A capture of a running VM is stamped as memory-and-disks")
    func runningCaptureIsWarm() async {
        let harness = makeHarness()
        let instance = makeInstance(status: .running)

        await harness.viewModel.takeSnapshot(instance, name: "Mid-session").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.warm])
        #expect(instance.snapshotManifest.snapshots.map(\.kind) == [.warm])
    }

    @Test("Taking a snapshot captures it and lists it as current")
    func takeSnapshotListsIt() async {
        let harness = makeHarness()
        let instance = makeInstance()

        await harness.viewModel.takeSnapshot(instance, name: "Clean install", notes: " tidy ").value

        #expect(harness.virtualization.takenSnapshots.map(\.name) == ["Clean install"])
        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Clean install"])
        #expect(instance.snapshotManifest.snapshots.first?.notes == "tidy")
        #expect(instance.snapshotManifest.currentID == instance.snapshotManifest.snapshots.first?.id)
        #expect(harness.snapshots.manifest(for: instance.bundleURL) == instance.snapshotManifest)
    }

    @Test("A blank name falls back to the next default")
    func blankNameFallsBackToTheDefault() async {
        let harness = makeHarness()
        let instance = makeInstance()

        await harness.viewModel.takeSnapshot(instance, name: "   ").value

        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Snapshot"])
    }

    @Test("A failed capture surfaces the error and lists nothing")
    func failedCaptureListsNothing() async {
        let harness = makeHarness()
        harness.virtualization.takeSnapshotError = VMSnapshotError.captureSourceMissing("Disk.asif")
        let instance = makeInstance()

        await harness.viewModel.takeSnapshot(instance, name: "Doomed").value

        #expect(instance.snapshotManifest.isEmpty)
        #expect(presenter.showError)
    }

    @Test("A manifest write that fails undoes the capture")
    func failedManifestWriteUndoesTheCapture() async {
        let harness = makeHarness()
        harness.snapshots.saveManifestError = VMStorageError.bundleNotFound(URL(filePath: "/tmp"))
        let instance = makeInstance()

        await harness.viewModel.takeSnapshot(instance, name: "Unlistable").value

        #expect(instance.snapshotManifest.isEmpty)
        #expect(harness.snapshots.removedDirectoryIDs.count == 1)
        #expect(presenter.showError)
    }

    // MARK: - Revert

    @Test("Requesting a revert opens the confirmation")
    func confirmRevertOpensTheAlert() {
        let harness = makeHarness()
        let instance = makeInstance()
        let snapshot = makeSnapshot()
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])

        harness.viewModel.confirmRevert(instance, to: snapshot)

        #expect(presenter.revertSnapshots == [snapshot])
    }

    @Test("A VM with no snapshots opens no revert confirmation")
    func confirmRevertRefusedWithoutSnapshots() {
        let harness = makeHarness()
        let instance = makeInstance()

        harness.viewModel.confirmRevert(instance, to: makeSnapshot())

        #expect(presenter.revertSnapshots.isEmpty)
    }

    @Test("Reverting moves the current marker to the snapshot")
    func revertMovesTheCurrentMarker() async {
        let harness = makeHarness()
        let instance = makeInstance()
        let target = makeSnapshot(name: "Fresh install")
        let other = VMSnapshot(name: "Later", createdAt: Date(timeIntervalSince1970: 1_700_001_000))
        seed(harness, instance, [target, other], currentID: other.id)

        await harness.viewModel.revertConfirmed(instance, to: target)

        #expect(harness.virtualization.revertedSnapshots == [target])
        #expect(instance.snapshotManifest.currentID == target.id)
        // The snapshot is kept, unlike the suspend slot.
        #expect(instance.snapshotManifest.snapshots.count == 2)
        // Nothing is left holding a quit back once the call returns.
        #expect(!harness.viewModel.hasRevertInFlight)
    }

    @Test("Reverting to an unlisted snapshot does nothing")
    func revertToAnUnlistedSnapshotDoesNothing() async {
        let harness = makeHarness()
        let instance = makeInstance()

        await harness.viewModel.revertConfirmed(instance, to: makeSnapshot())

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
    }

    @Test("A failed revert surfaces the error and leaves the marker alone")
    func failedRevertLeavesTheMarker() async {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        let instance = makeInstance()
        let target = makeSnapshot()
        seed(harness, instance, [target])

        await harness.viewModel.revertConfirmed(instance, to: target)

        #expect(instance.snapshotManifest.currentID == nil)
        #expect(presenter.showError)
    }

    @Test("Snapshot-then-revert captures first, then reverts")
    func snapshotThenRevertDoesBoth() async {
        let harness = makeHarness()
        let instance = makeInstance()
        let target = makeSnapshot()
        seed(harness, instance, [target])

        await harness.viewModel.snapshotThenRevertConfirmed(instance, to: target)

        #expect(harness.virtualization.takenSnapshots.count == 1)
        #expect(harness.virtualization.revertedSnapshots == [target])
        #expect(instance.snapshotManifest.snapshots.count == 2)
    }

    @Test("Snapshot-then-revert check-points a stopped VM disks-only before reverting")
    func snapshotThenRevertCheckPointsAStoppedVM() async {
        let harness = makeHarness()
        let instance = makeInstance(status: .stopped)
        var target = makeSnapshot()
        target.kind = .cold
        seed(harness, instance, [target])

        await harness.viewModel.snapshotThenRevertConfirmed(instance, to: target)

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.cold])
        #expect(harness.virtualization.revertedSnapshots == [target])
        #expect(instance.status == .stopped)
    }

    @Test("Snapshot-then-revert stops when the capture fails")
    func snapshotThenRevertStopsOnCaptureFailure() async {
        let harness = makeHarness()
        harness.virtualization.takeSnapshotError = VMSnapshotError.captureSourceMissing("Disk.asif")
        let instance = makeInstance()
        let target = makeSnapshot()
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [target])

        await harness.viewModel.snapshotThenRevertConfirmed(instance, to: target)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(presenter.showError)
    }

    @Test("A revert whose resume fails still marks the snapshot current")
    func revertMarksCurrentWhenTheResumeFails() async {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VirtualizationError.revertResumeFailed(
            underlying: VirtualizationError.noVirtualMachine)
        let instance = makeInstance()
        let target = makeSnapshot()
        seed(harness, instance, [target])

        await harness.viewModel.revertConfirmed(instance, to: target)

        // The files landed before the resume was attempted, so the VM's state
        // does descend from this snapshot.
        #expect(instance.snapshotManifest.currentID == target.id)
        #expect(presenter.showError)
    }

    @Test("A revert that never reached the files leaves the marker alone")
    func revertLeavesTheMarkerWhenTheRestoreFails() async {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        let instance = makeInstance()
        let target = makeSnapshot()
        seed(harness, instance, [target])

        await harness.viewModel.revertConfirmed(instance, to: target)

        #expect(instance.snapshotManifest.currentID == nil)
    }

    @Test("A revert installs the settings the snapshot captured, keeping the VM's identity")
    func revertInstallsTheCapturedSettings() async {
        let harness = makeHarness()
        let instance = makeInstance()
        let target = makeSnapshot()
        var captured = instance.configuration
        captured.memorySizeInGB = instance.configuration.memorySizeInGB + 8
        captured.name = "Name from the snapshot"
        seed(harness, instance, [target], capturedConfiguration: captured)
        let originalName = instance.configuration.name

        await harness.viewModel.revertConfirmed(instance, to: target)

        #expect(instance.configuration.memorySizeInGB == captured.memorySizeInGB)
        #expect(instance.configuration.name == originalName)
    }

    // MARK: - Gating

    @Test("A capture confirmed after the VM stopped is refused")
    func takeSnapshotRechecksAtConfirmTime() async {
        let harness = makeHarness()
        let instance = makeInstance()
        harness.viewModel.requestTakeSnapshot(instance)
        #expect(presenter.takeSnapshotSheetInstances.count == 1)

        // The sheet gathers a name, and the VM starts restoring while it is up.
        instance.status = .restoring
        await harness.viewModel.takeSnapshot(instance, name: "Too late").value

        #expect(harness.virtualization.takenSnapshots.isEmpty)
        #expect(instance.snapshotManifest.isEmpty)
    }

    @Test("A VM that stopped while the sheet was up is captured disks-only, not refused")
    func kindIsStampedAtConfirmTime() async {
        let harness = makeHarness()
        let instance = makeInstance(status: .running)
        harness.viewModel.requestTakeSnapshot(instance)

        instance.status = .stopped
        await harness.viewModel.takeSnapshot(instance, name: "Powered off first").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.cold])
    }

    @Test("A rename arriving while an operation is unsettled is refused")
    func renameRefusedWhileBusy() {
        let harness = makeHarness()
        let instance = makeInstance(status: .restoring)
        let snapshot = makeSnapshot()
        seed(harness, instance, [snapshot])

        harness.viewModel.renameSnapshot(snapshot, newName: "Renamed", on: instance)

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.name == snapshot.name)
        #expect(harness.snapshots.manifest(for: instance.bundleURL) == nil)
    }

    // MARK: - Delete

    @Test("Requesting a delete opens the confirmation")
    func confirmDeleteOpensTheAlert() {
        let harness = makeHarness()
        let instance = makeInstance()
        let snapshot = makeSnapshot()

        harness.viewModel.confirmDeleteSnapshot(instance, snapshot: snapshot)

        #expect(presenter.deleteSnapshots == [snapshot])
    }

    @Test("Deleting trashes the snapshot's files and drops it from the manifest")
    func deleteTrashesAndUnlists() async {
        let harness = makeHarness()
        let instance = makeInstance()
        let snapshot = makeSnapshot()
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [snapshot], currentID: snapshot.id)

        await harness.viewModel.deleteSnapshotConfirmed(instance, snapshot: snapshot).value

        #expect(harness.snapshots.discardedIDs == [snapshot.id])
        #expect(instance.snapshotManifest.isEmpty)
        #expect(instance.snapshotManifest.currentID == nil)
    }

    @Test("A failed delete surfaces the error and keeps the snapshot listed")
    func failedDeleteKeepsTheSnapshot() async {
        let harness = makeHarness()
        harness.snapshots.discardError = VMStorageError.bundleNotFound(URL(filePath: "/tmp"))
        let instance = makeInstance()
        let snapshot = makeSnapshot()
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])

        await harness.viewModel.deleteSnapshotConfirmed(instance, snapshot: snapshot).value

        #expect(instance.snapshotManifest.snapshots == [snapshot])
        #expect(presenter.showError)
    }

    // MARK: - Rename

    @Test("Renaming writes the new name through to the manifest")
    func renameWritesThrough() {
        let harness = makeHarness()
        let instance = makeInstance()
        let snapshot = makeSnapshot()
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])

        harness.viewModel.renameSnapshot(snapshot, newName: "  Renamed  ", on: instance)

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.name == "Renamed")
        #expect(harness.snapshots.manifest(for: instance.bundleURL) == instance.snapshotManifest)
    }

    @Test("A blank or unchanged rename writes nothing")
    func renameNoOps() {
        let harness = makeHarness()
        let instance = makeInstance()
        let snapshot = makeSnapshot()
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])

        harness.viewModel.renameSnapshot(snapshot, newName: "   ", on: instance)
        harness.viewModel.renameSnapshot(snapshot, newName: snapshot.name, on: instance)

        #expect(harness.snapshots.manifest(for: instance.bundleURL) == nil)
    }

    // MARK: - Sizes

    @Test("On-disk sizes come back keyed by snapshot")
    func onDiskSizesAreReported() async {
        let harness = makeHarness()
        let instance = makeInstance()
        let snapshot = makeSnapshot()
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])
        harness.snapshots.setSize(4_200_000_000, for: snapshot.id)

        let sizes = await harness.viewModel.snapshotOnDiskBytes(for: instance)

        #expect(sizes[snapshot.id] == 4_200_000_000)
    }

    @Test("A VM with no snapshots reads no sizes")
    func onDiskSizesEmptyWithoutSnapshots() async {
        let harness = makeHarness()
        let sizes = await harness.viewModel.snapshotOnDiskBytes(for: makeInstance())
        #expect(sizes.isEmpty)
    }
}
