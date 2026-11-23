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
        _ machineFiles: MockVMBundleMachineFiles, _ instance: VMInstance, _ snapshots: [VMSnapshot],
        currentID: UUID? = nil, capturedConfiguration: VMConfiguration? = nil
    ) {
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: snapshots, currentID: currentID))
        for snapshot in snapshots {
            machineFiles.setCapturedConfiguration(
                capturedConfiguration ?? instance.configuration, for: snapshot.id)
        }
    }

    // MARK: - Seeding

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

        await harness.viewModel.library.loadVMs()
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

    @Test("Taking a snapshot captures it and lists it as current")
    func takeSnapshotListsIt() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        try await harness.viewModel.takeSnapshot(instance, name: "Clean install", notes: " tidy ").joined()

        #expect(harness.virtualization.takenSnapshots.map(\.name) == ["Clean install"])
        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Clean install"])
        #expect(instance.snapshotManifest.snapshots.first?.notes == "tidy")
        #expect(instance.snapshotManifest.currentID == instance.snapshotManifest.snapshots.first?.id)
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
    }

    /// The snapshot stands as a restore point either way, so a baseline
    /// write that fails keeps it listed and says the mode stayed off.
    @Test("A baseline write that fails keeps the snapshot and reports the mode off")
    func failedBaselineWriteKeepsTheSnapshot() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        instance.fixtureBundleFiles.setReplaceError(
            VMStorageError.bundleNotFound(URL(filePath: "/tmp")),
            for: VMBundleLayout.hostStateRelativePath)

        try await harness.viewModel.takeSnapshot(instance, name: "Kept", for: .ephemeralBaseline).joined()

        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Kept"])
        #expect(instance.manifestOnDisk == instance.snapshotManifest)
        #expect(!instance.hostState.ephemeralModeEnabled)
        #expect(presenter.showError)
    }

    @Test("A restore point leaves Ephemeral Mode alone")
    func restorePointLeavesTheModeAlone() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)

        try await harness.viewModel.takeSnapshot(instance, name: "Plain").joined()

        #expect(!instance.hostState.ephemeralModeEnabled)
    }

    @Test("A manifest write that fails undoes the capture")
    func failedManifestWriteUndoesTheCapture() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        instance.fixtureBundleFiles.setReplaceError(
            VMStorageError.bundleNotFound(URL(filePath: "/tmp")),
            for: VMBundleLayout.snapshotManifestRelativePath)

        try await harness.viewModel.takeSnapshot(instance, name: "Unlistable").joined()

        #expect(instance.snapshotManifest.isEmpty)
        #expect(harness.snapshots.removedDirectoryIDs.count == 1)
        #expect(presenter.showError)
    }

    @Test("A snapshot taken over a manifest copied in after load lists both")
    func captureOverACopiedInManifestListsBoth() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files)
        // The manifest lands in the bundle after the VM was read with none.
        let copiedIn = makeSnapshot(name: "Copied in")
        harness.storage.files.setManifest(
            VMSnapshotManifest(snapshots: [copiedIn], currentID: copiedIn.id), at: instance.bundleURL)

        try await harness.viewModel.takeSnapshot(instance, name: "Taken here").joined()

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
        seed(harness.snapshots, instance, [snapshot])

        harness.viewModel.requestRevert(instance, to: snapshot)

        #expect(presenter.revertSnapshots == [snapshot])
    }

    @Test("Snapshot-then-revert check-points a stopped VM cold before reverting")
    func snapshotThenRevertCheckPointsAStoppedVM() async {
        let harness = makeHarness()
        let instance = makeInstance(in: harness.viewModel, files: harness.storage.files, phase: .stopped)
        var target = makeSnapshot()
        target.record.kind = .cold
        seed(harness.snapshots, instance, [target])

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
        seed(harness.snapshots, instance, [target])

        await harness.viewModel.revert(instance, to: target, takingSnapshotFirst: true)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(presenter.showError)
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
}
