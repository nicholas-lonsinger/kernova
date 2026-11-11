import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMLibraryViewModel Snapshot Tests", .serialized, .caseScoped)
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
            virtualizationHost: FakeVirtualizationHost(),
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: MockLocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: MockBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
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
            virtualizationHost: FakeVirtualizationHost(),
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: MockLocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: MockBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
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
        viewModel.library.admitFixture(
            name: name, phase: phase, preferences: preferences, files: files, mutate: mutate)
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

    @Test("Launch reclaims what an interrupted revert or resume left, and a load alone does not")
    func launchSweepsInterruptedWork() async throws {
        let harness = makeHarness()
        let config = VMConfiguration(
            name: "Interrupted", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let bundleURL = try harness.storage.bundleURL(for: config)
        harness.storage.setConfiguration(config, at: bundleURL)
        let spentSlot = VMBundleLayout(bundleURL: bundleURL).spentSaveFileURL
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("spent".utf8).write(to: spentSlot)

        await harness.viewModel.loadVMs()
        #expect(harness.snapshots.sweptStagingBundleURLs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: spentSlot.path(percentEncoded: false)))

        await harness.viewModel.startLibrary()
        // Otherwise the reclaim waits on the next revert of this same VM, which
        // may never come — and its clones own their blocks outright once the
        // snapshot they were cloned from is discarded.
        #expect(harness.snapshots.sweptStagingBundleURLs == [bundleURL])
        #expect(!FileManager.default.fileExists(atPath: spentSlot.path(percentEncoded: false)))
    }

    // MARK: - Take

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

        let outcome = harness.viewModel.setConfiguration(
            [VMConfigurationKeyRegistry.networkMAC.assigning("aa:bb:cc:dd:ee:05")], on: other)

        #expect(outcome == .refused)
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

    /// The baseline is the capture's own result, not whichever snapshot the
    /// mode would default to, so the Current one — named first here — is
    /// passed over.
    @Test("The baseline is the capture's snapshot even beside another")
    func baselineIsTheCapturesSnapshot() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let earlier = makeSnapshot(name: "Earlier")
        seed(harness, instance, [earlier], currentID: earlier.id)

        await harness.viewModel.takeSnapshot(
            instance, name: "Baseline", for: .ephemeralBaseline
        ).value

        let captured = try #require(
            instance.snapshotManifest.snapshots.first { $0.name == "Baseline" })
        #expect(instance.hostState.ephemeralBaselineSnapshotID == captured.id)
    }

    /// The snapshot stands as a restore point either way, so a baseline
    /// write that fails keeps it listed and says the mode stayed off.
    @Test("A baseline write that fails keeps the snapshot and reports the mode off")
    func failedBaselineWriteKeepsTheSnapshot() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        instance.fixtureBundleFiles.setReplaceError(
            VMStorageError.bundleNotFound(URL(filePath: "/tmp")),
            for: VMBundleLayout.hostStateRelativePath)

        await harness.viewModel.takeSnapshot(instance, name: "Kept", for: .ephemeralBaseline).value

        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Kept"])
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
        #expect(!instance.hostState.ephemeralModeEnabled)
        #expect(presenter.showError)
    }

    @Test("A restore point leaves Ephemeral Mode alone")
    func restorePointLeavesTheModeAlone() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        await harness.viewModel.takeSnapshot(instance, name: "Plain").value

        #expect(!instance.hostState.ephemeralModeEnabled)
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

    @Test("Snapshot-then-revert check-points a stopped VM cold before reverting")
    func snapshotThenRevertCheckPointsAStoppedVM() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files, phase: .stopped)
        var target = makeSnapshot()
        target.record.kind = .cold
        seed(harness, instance, [target])

        await harness.viewModel.revert(instance, to: target, takingSnapshotFirst: true)

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

        await harness.viewModel.revert(instance, to: target, takingSnapshotFirst: true)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(presenter.showError)
    }

    // MARK: - Gating

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

    @Test("A snapshot delete whose trash fails leaves no manifest entry pointing at it")
    func deleteWhoseTrashFailsLeavesItUnlisted() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        let snapshot = makeSnapshot()
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id))
        harness.snapshots.setDiscardError(CocoaError(.fileWriteNoPermission))

        await harness.viewModel.deleteSnapshot(instance, snapshot: snapshot, turningOffEphemeralMode: false).value

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
}
