import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMLibraryViewModel Snapshot Tests", .serialized, .admissionGated)
@MainActor
struct VMLibraryViewModelSnapshotTests {
    private let presenter = MockVMLibraryPresenting()
    private let preferences = makeTestPreferences()

    private struct Harness {
        let viewModel: VMLibraryViewModel
        let storage: MockVMStorageService
        let virtualization: MockVirtualizationService
        let snapshots: MockVMBundleMachineFiles
    }

    private func makeHarness() -> Harness {
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
        let snapshots = MockVMBundleMachineFiles(files: storage.files)
        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            machineFiles: snapshots,
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
        viewModel.presenter = presenter
        return Harness(
            viewModel: viewModel, storage: storage, virtualization: virtualization,
            snapshots: snapshots)
    }

    private struct SuspendingHarness {
        let viewModel: VMLibraryViewModel
        let storage: MockVMStorageService
        let virtualization: SuspendingMockVirtualizationService
        let snapshots: MockVMBundleMachineFiles
    }

    /// A harness whose virtualization service holds the revert suspended until
    /// released, so a test can land another mutation while the revert is in
    /// flight and observe whether it survives.
    private func makeSuspendingHarness() -> SuspendingHarness {
        let virtualization = SuspendingMockVirtualizationService()
        let storage = MockVMStorageService()
        let snapshots = MockVMBundleMachineFiles(files: storage.files)
        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            machineFiles: snapshots,
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
        viewModel.presenter = presenter
        return SuspendingHarness(
            viewModel: viewModel, storage: storage, virtualization: virtualization,
            snapshots: snapshots)
    }

    /// A VM registered in `viewModel`'s library — every verb addresses a VM by
    /// selector, so one outside the library resolves to nothing.
    private func makeInstance(
        in viewModel: VMLibraryViewModel, files: InMemoryVMBundleFiles,
        phase: VMLifecyclePhase = .running(sessionID: UUID()),
        name: String = "Snapshot VM", _ mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(
            name: name, phase: phase, preferences: preferences, files: files,
            bundleFactory: viewModel.library.bundleFactory, mutate: mutate)
        viewModel.library.admitForTesting(instance)
        return instance
    }

    private func makeSnapshot(name: String = "Before the update") -> VMSnapshot {
        VMSnapshot(name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000), macAddress: nil)
    }

    /// Lists `snapshots` on `instance` and records what each captured, so a
    /// revert finds the configuration a real snapshot directory would hold.
    private func seed(
        _ harness: Harness, _ instance: VMInstance, _ snapshots: [VMSnapshot],
        currentID: UUID? = nil, capturedConfiguration: VMConfiguration? = nil
    ) {
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: snapshots, currentID: currentID))
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
        harness.storage.files.setManifest(
            VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id), at: bundleURL)

        await harness.viewModel.loadVMs()

        #expect(harness.viewModel.instances.first?.snapshotManifest.snapshots == [snapshot])
        #expect(harness.viewModel.instances.first?.snapshotManifest.currentID == snapshot.id)
    }

    @Test("Launch reclaims the staging directory an interrupted revert left, and a load alone does not")
    func launchSweepsRevertStaging() async throws {
        let harness = makeHarness()
        let config = VMConfiguration(name: "Interrupted", guestOS: .linux, bootMode: .efi)
        let bundleURL = try harness.storage.bundleURL(for: config)
        harness.storage.bundles[bundleURL] = config

        await harness.viewModel.loadVMs()
        #expect(harness.snapshots.sweptStagingBundleURLs.isEmpty)

        await harness.viewModel.startLibrary()
        // Otherwise the reclaim waits on the next revert of this same VM, which
        // may never come — and its clones own their blocks outright once the
        // snapshot they were cloned from is discarded.
        #expect(harness.snapshots.sweptStagingBundleURLs == [bundleURL])
    }

    // MARK: - Take

    @Test("Requesting a snapshot opens the sheet")
    func requestOpensTheSheet() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        harness.viewModel.requestTakeSnapshot(instance)

        #expect(presenter.takeSnapshotSheetInstances.count == 1)
    }

    @Test("A VM with nothing settled to capture opens no sheet")
    func requestRefusedWhileTransitioning() {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness.viewModel, files: harness.storage.files,
            phase: .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped))

        harness.viewModel.requestTakeSnapshot(instance)

        #expect(presenter.takeSnapshotSheetInstances.isEmpty)
    }

    @Test("A capture of a stopped VM is stamped as disks-only")
    func stoppedCaptureIsCold() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files, phase: .stopped)

        await harness.viewModel.takeSnapshot(instance, name: "Before first boot").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.cold])
        #expect(instance.snapshotManifest.snapshots.map(\.kind) == [.cold])
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
        #expect(instance.phase == .stopped)
    }

    @Test("A capture of a cold-paused VM is stamped as memory-and-disks and lands in the manifest")
    func coldPausedCaptureIsWarm() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files, phase: .suspended)
        // A capturable suspend slot: `canTakeSnapshot` for a cold-paused VM
        // needs one on disk, not just the status.
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        FileManager.default.createFile(
            atPath: instance.bundleLayout.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))

        await harness.viewModel.takeSnapshot(instance, name: "Suspended").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.warm])
        #expect(instance.snapshotManifest.snapshots.map(\.kind) == [.warm])
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
        #expect(instance.phase == .suspended)
        #expect(!instance.hasLiveVirtualMachine)
    }

    @Test("A capture of a running VM is stamped as memory-and-disks")
    func runningCaptureIsWarm() async {
        let harness = makeHarness()
        let sessionID = UUID()
        let instance = makeInstance(
            in: harness.viewModel, files: harness.storage.files, phase: .running(sessionID: sessionID))

        await harness.viewModel.takeSnapshot(instance, name: "Mid-session").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.warm])
        #expect(instance.snapshotManifest.snapshots.map(\.kind) == [.warm])
        #expect(instance.phase == .running(sessionID: sessionID))
    }

    @Test("A capture of a live-paused VM is stamped as memory-and-disks and stays live-paused")
    func livePausedCaptureIsWarm() async {
        let harness = makeHarness()
        let sessionID = UUID()
        let instance = makeInstance(
            in: harness.viewModel, files: harness.storage.files, phase: .livePaused(sessionID: sessionID))

        await harness.viewModel.takeSnapshot(instance, name: "Paused mid-session").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.warm])
        #expect(instance.phase == .livePaused(sessionID: sessionID))
    }

    @Test("A snapshot is listed carrying the MAC address it was taken with")
    func takenSnapshotCarriesItsMACAddress() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files) {
            $0.macAddress = "aa:bb:cc:dd:ee:04"
        }

        await harness.viewModel.takeSnapshot(instance, name: "Clean install").value

        #expect(instance.snapshotManifest.snapshots.map(\.macAddress) == ["aa:bb:cc:dd:ee:04"])
    }

    @Test("An Ephemeral baseline keeps the address it was taken with from every other VM")
    func ephemeralBaselineReservesItsAddress() async throws {
        let harness = makeHarness()
        let ephemeral = makeInstance(
            in: harness.viewModel, files: harness.storage.files, phase: .stopped, name: "Ephemeral"
        ) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:05"
        }
        await harness.viewModel.takeSnapshot(ephemeral, name: "Baseline").value
        let baseline = try #require(ephemeral.snapshotManifest.snapshots.first)
        // The VM itself may leave the address, which its baseline still holds.
        #expect(
            try harness.viewModel.library.updateSettings(
                of: ephemeral, as: [.machineKeys, .liveKeys],
                configuration: { $0.macAddress = "aa:bb:cc:dd:ee:06" },
                hostState: { $0.applyEphemeralMode(enabled: true, baseline: baseline.id) }
            ).landed)
        let other = makeInstance(in: harness.viewModel, files: harness.storage.files, phase: .stopped, name: "Other") {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:07"
        }

        let took = try harness.viewModel.library.updateConfiguration(of: other, as: .machineKeys) {
            $0.macAddress = "aa:bb:cc:dd:ee:05"
        }

        #expect(took.refusedForMACAddress)
        #expect(other.configuration.macAddress == "aa:bb:cc:dd:ee:07")
        #expect(presenter.errorTitles == ["MAC Address In Use"])
        // The baseline is named as one, and offered no delete it would refuse.
        #expect(
            presenter.errorMessage
                == "\u{201C}Ephemeral\u{201D} has a snapshot, \u{201C}Baseline\u{201D}, taken with aa:bb:cc:dd:ee:05. "
                + "\u{201C}Baseline\u{201D} is its Ephemeral Mode baseline. "
                + "Each virtual machine needs its own MAC address.")

        // The power-off revert puts the VM back on the baseline's address,
        // which nothing else took meanwhile.
        await harness.viewModel.revert(ephemeral, to: baseline)
        #expect(ephemeral.configuration.macAddress == "aa:bb:cc:dd:ee:05")
        #expect(ephemeral.hostState.ephemeralModeEnabled)
        #expect(harness.viewModel.vmNamesSharingMACAddress(with: ephemeral).isEmpty)
    }

    @Test("Taking a snapshot captures it and lists it as current")
    func takeSnapshotListsIt() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        await harness.viewModel.takeSnapshot(instance, name: "Clean install", notes: " tidy ").value

        #expect(harness.virtualization.takenSnapshots.map(\.name) == ["Clean install"])
        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Clean install"])
        #expect(instance.snapshotManifest.snapshots.first?.notes == "tidy")
        #expect(instance.snapshotManifest.currentID == instance.snapshotManifest.snapshots.first?.id)
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
    }

    @Test("A blank name falls back to the next default")
    func blankNameFallsBackToTheDefault() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        await harness.viewModel.takeSnapshot(instance, name: "   ").value

        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Snapshot"])
    }

    @Test("A failed capture surfaces the error and lists nothing")
    func failedCaptureListsNothing() async {
        let harness = makeHarness()
        harness.virtualization.takeSnapshotError = VMSnapshotError.captureSourceMissing("Disk.asif")
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        await harness.viewModel.takeSnapshot(instance, name: "Doomed").value

        #expect(instance.snapshotManifest.isEmpty)
        #expect(presenter.showError)
    }

    @Test("A manifest write that fails undoes the capture")
    func failedManifestWriteUndoesTheCapture() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        instance.fixtureBundleFiles.setReplaceError(
            VMStorageError.bundleNotFound(URL(filePath: "/tmp")),
            for: VMBundleLayout.snapshotManifestRelativePath)

        await harness.viewModel.takeSnapshot(instance, name: "Unlistable").value

        #expect(instance.snapshotManifest.isEmpty)
        #expect(harness.snapshots.removedDirectoryIDs.count == 1)
        #expect(presenter.showError)
    }

    @Test("A snapshot taken over a manifest copied in after load lists both")
    func captureOverACopiedInManifestListsBoth() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        // The manifest lands in the bundle after the VM was read with none.
        let copiedIn = makeSnapshot(name: "Copied in")
        harness.storage.files.setManifest(
            VMSnapshotManifest(snapshots: [copiedIn], currentID: copiedIn.id), at: instance.bundleURL)

        await harness.viewModel.takeSnapshot(instance, name: "Taken here").value

        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Copied in", "Taken here"])
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
        #expect(!presenter.showError)
    }

    @Test("A snapshot taken after a failed configuration write captures what the bundle holds")
    func captureAfterAFailedConfigurationWriteTakesTheBundleConfiguration() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let held = instance.configuration
        harness.storage.saveConfigurationError = NSError(domain: "test", code: 1)
        let write = try harness.viewModel.library.updateConfiguration(of: instance, as: .rename) {
            $0.name = "Renamed"
        }
        #expect(write.failedToSave)
        harness.storage.saveConfigurationError = nil

        await harness.viewModel.takeSnapshot(instance, name: "After the failure").value

        let snapshot = try #require(instance.snapshotManifest.snapshots.first)
        let captured = try harness.snapshots.planRestore(
            bundleURL: instance.bundleURL, snapshotID: snapshot.id, kind: snapshot.kind
        ).configuration
        #expect(captured == held)
        #expect(captured == harness.storage.bundles[instance.bundleURL])
    }

    // MARK: - Revert

    @Test("Requesting a revert opens the confirmation")
    func requestRevertOpensTheAlert() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        harness.viewModel.requestRevert(instance, to: snapshot)

        #expect(presenter.revertSnapshots == [snapshot])
    }

    @Test("A VM with no snapshots opens no revert confirmation")
    func requestRevertRefusedWithoutSnapshots() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        harness.viewModel.requestRevert(instance, to: makeSnapshot())

        #expect(presenter.revertSnapshots.isEmpty)
    }

    @Test("Reverting moves the current marker to the snapshot")
    func revertMovesTheCurrentMarker() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let target = makeSnapshot(name: "Fresh install")
        let other = VMSnapshot(name: "Later", createdAt: Date(timeIntervalSince1970: 1_700_001_000), macAddress: nil)
        seed(harness, instance, [target, other], currentID: other.id)

        await harness.viewModel.revert(instance, to: target)

        #expect(harness.virtualization.revertedSnapshots == [target])
        #expect(instance.snapshotManifest.currentID == target.id)
        // The snapshot is kept, unlike the suspend slot.
        #expect(instance.snapshotManifest.snapshots.count == 2)
        // Nothing is left holding a quit back once the call returns.
        #expect(!harness.viewModel.quitMustWaitOut)
    }

    @Test("Reverting to an unlisted snapshot does nothing")
    func revertToAnUnlistedSnapshotDoesNothing() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        await harness.viewModel.revert(instance, to: makeSnapshot())

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
    }

    @Test("A failed revert surfaces the error and leaves the marker alone")
    func failedRevertLeavesTheMarker() async {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let target = makeSnapshot()
        seed(harness, instance, [target])

        await harness.viewModel.revert(instance, to: target)

        #expect(instance.snapshotManifest.currentID == nil)
        #expect(presenter.showError)
    }

    @Test("Snapshot-then-revert captures first, then reverts")
    func snapshotThenRevertDoesBoth() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let target = makeSnapshot()
        seed(harness, instance, [target])

        await harness.viewModel.revert(instance, to: target, takingCheckpoint: true)

        #expect(harness.virtualization.takenSnapshots.count == 1)
        #expect(harness.virtualization.revertedSnapshots == [target])
        #expect(instance.snapshotManifest.snapshots.count == 2)
    }

    @Test("Snapshot-then-revert check-points a stopped VM disks-only before reverting")
    func snapshotThenRevertCheckPointsAStoppedVM() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files, phase: .stopped)
        var target = makeSnapshot()
        target.record.kind = .cold
        seed(harness, instance, [target])

        await harness.viewModel.revert(instance, to: target, takingCheckpoint: true)

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.cold])
        #expect(harness.virtualization.revertedSnapshots == [target])
        #expect(instance.status == .stopped)
    }

    @Test("Snapshot-then-revert stops when the capture fails")
    func snapshotThenRevertStopsOnCaptureFailure() async {
        let harness = makeHarness()
        harness.virtualization.takeSnapshotError = VMSnapshotError.captureSourceMissing("Disk.asif")
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let target = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [target]))

        await harness.viewModel.revert(instance, to: target, takingCheckpoint: true)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(presenter.showError)
    }

    @Test("A revert whose resume fails still marks the snapshot current")
    func revertMarksCurrentWhenTheResumeFails() async {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VirtualizationError.revertResumeFailed(
            underlying: VirtualizationError.noVirtualMachine)
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let target = makeSnapshot()
        seed(harness, instance, [target])

        await harness.viewModel.revert(instance, to: target)

        // The files landed before the resume was attempted, so the VM's state
        // does descend from this snapshot.
        #expect(instance.snapshotManifest.currentID == target.id)
        #expect(presenter.showError)
    }

    @Test("A revert that never reached the files leaves the marker alone")
    func revertLeavesTheMarkerWhenTheRestoreFails() async {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let target = makeSnapshot()
        seed(harness, instance, [target])

        await harness.viewModel.revert(instance, to: target)

        #expect(instance.snapshotManifest.currentID == nil)
    }

    @Test("A revert installs the settings the snapshot captured, keeping the VM's identity")
    func revertInstallsTheCapturedSettings() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let target = makeSnapshot()
        var captured = instance.configuration
        captured.memorySizeInGB = instance.configuration.memorySizeInGB + 8
        captured.name = "Name from the snapshot"
        seed(harness, instance, [target], capturedConfiguration: captured)
        let originalName = instance.configuration.name

        await harness.viewModel.revert(instance, to: target)

        #expect(instance.configuration.memorySizeInGB == captured.memorySizeInGB)
        #expect(instance.configuration.name == originalName)
    }

    // MARK: - Gating

    @Test("A capture confirmed after the VM stopped is refused")
    func takeSnapshotRechecksAtConfirmTime() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        harness.viewModel.requestTakeSnapshot(instance)
        #expect(presenter.takeSnapshotSheetInstances.count == 1)

        // The sheet gathers a name, and the VM starts restoring while it is up.
        instance.activity.placeForTesting(
            .operating(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped))
        await harness.viewModel.takeSnapshot(instance, name: "Too late").value

        #expect(harness.virtualization.takenSnapshots.isEmpty)
        #expect(instance.snapshotManifest.isEmpty)
    }

    @Test("A VM that stopped while the sheet was up is captured disks-only, not refused")
    func kindIsStampedAtConfirmTime() async {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness.viewModel, files: harness.storage.files, phase: .running(sessionID: UUID()))
        harness.viewModel.requestTakeSnapshot(instance)

        instance.activity.placeForTesting(.stopped)
        await harness.viewModel.takeSnapshot(instance, name: "Powered off first").value

        #expect(harness.virtualization.takenSnapshots.map(\.kind) == [.cold])
    }

    @Test("A rename arriving while an operation is unsettled still lands")
    func renameLandsWhileAnOperationIsUnsettled() {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness.viewModel, files: harness.storage.files,
            phase: .operating(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped))
        let snapshot = makeSnapshot()
        seed(harness, instance, [snapshot])

        harness.viewModel.renameSnapshot(snapshot, newName: "Renamed", on: instance)

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.name == "Renamed")
        #expect(instance.manifestOnDisk?.snapshot(id: snapshot.id)?.name == "Renamed")
    }

    // MARK: - Delete

    @Test("Requesting a delete opens the confirmation")
    func requestDeleteOpensTheAlert() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()

        harness.viewModel.requestDeleteSnapshot(instance, snapshot: snapshot)

        #expect(presenter.deleteSnapshots == [snapshot])
    }

    @Test("Deleting trashes the snapshot's files and drops it from the manifest")
    func deleteTrashesAndUnlists() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: [snapshot], currentID: snapshot.id))

        await harness.viewModel.deleteSnapshot(instance, snapshot: snapshot).value

        #expect(harness.snapshots.discardedIDs == [snapshot.id])
        #expect(instance.snapshotManifest.isEmpty)
        #expect(instance.snapshotManifest.currentID == nil)
    }

    @Test("A delete whose unlisting fails surfaces the error, keeps the snapshot listed, and trashes nothing")
    func failedDeleteKeepsTheSnapshot() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        harness.storage.files.setReplaceError(
            VMStorageError.bundleNotFound(URL(filePath: "/tmp")),
            for: VMBundleLayout.snapshotManifestRelativePath)

        await harness.viewModel.deleteSnapshot(instance, snapshot: snapshot).value

        #expect(instance.snapshotManifest.snapshots == [snapshot])
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
        #expect(harness.snapshots.discardedIDs.isEmpty)
        #expect(presenter.showError)
    }

    @Test("A snapshot delete whose trash fails leaves no manifest entry pointing at it")
    func deleteWhoseTrashFailsLeavesItUnlisted() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id))
        harness.snapshots.discardError = CocoaError(.fileWriteNoPermission)

        await harness.viewModel.deleteSnapshot(instance, snapshot: snapshot).value

        #expect(instance.snapshotManifest.isEmpty)
        #expect(instance.snapshotManifest.currentID == nil)
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
        #expect(harness.snapshots.discardedIDs.isEmpty)
        #expect(presenter.errorMessage?.contains("was removed from the list") == true)
    }

    // MARK: - Rename

    @Test("Renaming writes the new name through to the manifest")
    func renameWritesThrough() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        harness.viewModel.renameSnapshot(snapshot, newName: "  Renamed  ", on: instance)

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.name == "Renamed")
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
    }

    @Test("A blank or unchanged rename writes nothing")
    func renameNoOps() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        harness.viewModel.renameSnapshot(snapshot, newName: "   ", on: instance)
        harness.viewModel.renameSnapshot(snapshot, newName: snapshot.name, on: instance)

        #expect(instance.fixtureBundleFiles.replaceCount(of: VMBundleLayout.snapshotManifestRelativePath) == 0)
    }

    // MARK: - Notes

    @Test("A note writes through to the manifest, trimmed at its edges")
    func notesWriteThrough() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        harness.viewModel.setSnapshotNotes(
            snapshot, notes: "  tools\nconfigured  ", on: instance)

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.notes == "tools\nconfigured")
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
    }

    @Test("An unchanged note writes nothing")
    func notesNoOpWritesNothing() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        var snapshot = makeSnapshot()
        snapshot.notes = "before the update"
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        harness.viewModel.setSnapshotNotes(snapshot, notes: "before the update", on: instance)

        #expect(instance.fixtureBundleFiles.replaceCount(of: VMBundleLayout.snapshotManifestRelativePath) == 0)
    }

    @Test("Clearing a note to empty is written, unlike an empty name")
    func notesClearToEmptyWritesThrough() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        var snapshot = makeSnapshot()
        snapshot.notes = "before the update"
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        harness.viewModel.setSnapshotNotes(snapshot, notes: "   ", on: instance)

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.notes == "")
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
    }

    @Test("A note arriving while an operation is unsettled still lands")
    func notesLandWhileAnOperationIsUnsettled() {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness.viewModel, files: harness.storage.files,
            phase: .operating(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped))
        let snapshot = makeSnapshot()
        seed(harness, instance, [snapshot])

        harness.viewModel.setSnapshotNotes(snapshot, notes: "late", on: instance)

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.notes == "late")
        #expect(instance.manifestOnDisk?.snapshot(id: snapshot.id)?.notes == "late")
    }

    @Test("A rename made mid-revert survives the revert's own manifest write")
    func renameSurvivesAConcurrentRevert() async {
        let harness = makeSuspendingHarness()
        harness.virtualization.shouldSuspendOnRevert = true
        // At rest when the revert is asked for — the verb refuses a VM already
        // mid-operation — and parked mid-copy by the suspending service below.
        let instance = makeInstance(
            in: harness.viewModel, files: harness.storage.files, phase: .running(sessionID: UUID()))
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: snapshot.id)

        let revertTask = Task { await harness.viewModel.revert(instance, to: snapshot) }
        // The revert is parked mid-copy, and the rename lands here — the
        // assertion below only holds if `performRevert` re-reads the manifest
        // after this await rather than writing a copy captured before it.
        await harness.virtualization.waitUntilSuspended()
        harness.viewModel.renameSnapshot(snapshot, newName: "Renamed mid-revert", on: instance)
        harness.virtualization.resumeSuspended()
        await revertTask.value

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.name == "Renamed mid-revert")
        #expect(instance.snapshotManifest.currentID == snapshot.id)
        #expect(
            instance.manifestOnDisk?.snapshot(id: snapshot.id)?.name
                == "Renamed mid-revert")
    }

    // MARK: - Sizes

    @Test("On-disk sizes come back keyed by snapshot")
    func onDiskSizesAreReported() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        harness.snapshots.setSize(4_200_000_000, for: snapshot.id)

        let sizes = await harness.viewModel.snapshotOnDiskBytes(for: instance)

        #expect(sizes[snapshot.id] == 4_200_000_000)
    }

    @Test("A VM with no snapshots reads no sizes")
    func onDiskSizesEmptyWithoutSnapshots() async {
        let harness = makeHarness()
        let sizes = await harness.viewModel.snapshotOnDiskBytes(
            for: makeInstance(in: harness.viewModel, files: harness.storage.files))
        #expect(sizes.isEmpty)
    }
}
