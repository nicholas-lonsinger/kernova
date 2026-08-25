import Foundation
import Testing

@testable import Kernova

/// The Ephemeral Mode policy: what a power-off does, what a suspend doesn't,
/// and what the baseline is protected from.
@Suite("VMLibraryViewModel Ephemeral Mode Tests", .serialized, .admissionGated)
@MainActor
struct VMLibraryViewModelEphemeralTests {
    private let presenter = MockVMLibraryPresenting()
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.ephemeral")

    private struct Harness {
        let viewModel: VMLibraryViewModel
        let storage: MockVMStorageService
        let virtualization: MockVirtualizationService
        let snapshots: MockVMSnapshotStore
        let instance: VMInstance
        let baseline: VMSnapshot
        let later: VMSnapshot
    }

    /// Loads one VM through the view model — the path that wires the power-off
    /// hook — carrying two snapshots, the older of which is the baseline.
    ///
    /// `ephemeral` decides whether the mode is on; `status` is where the VM
    /// rests once loaded.
    private func makeHarness(
        ephemeral: Bool = true, status: VMStatus = .running
    ) async throws -> Harness {
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
        let snapshots = MockVMSnapshotStore()

        let baseline = VMSnapshot(
            name: "Clean install", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let later = VMSnapshot(
            name: "Mid-session", createdAt: Date(timeIntervalSince1970: 1_700_001_000))

        var config = VMConfiguration(name: "Throwaway", guestOS: .linux, bootMode: .efi)
        if ephemeral {
            config.applyEphemeralMode(enabled: true, baseline: baseline.id)
        }
        let bundleURL = try storage.bundleURL(for: config)
        storage.bundles[bundleURL] = config
        snapshots.setManifest(
            VMSnapshotManifest(snapshots: [baseline, later], currentID: later.id), for: bundleURL)
        // What each snapshot's own config.json holds, so a revert has something
        // to read back.
        for snapshot in [baseline, later] {
            snapshots.setCapturedConfiguration(config, for: snapshot.id)
        }

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
        await viewModel.loadVMs()
        let instance = viewModel.instances[0]
        instance.status = status

        return Harness(
            viewModel: viewModel, storage: storage, virtualization: virtualization,
            snapshots: snapshots, instance: instance, baseline: baseline, later: later)
    }

    /// Awaits the revert a power-off started, if it started one.
    private func settleEphemeralRevert(_ harness: Harness) async {
        await harness.viewModel.ephemeralRevertTaskForTesting?.value
    }

    // MARK: - Power-off

    @Test("A graceful stop returns an ephemeral VM to its baseline")
    func stopRevertsToTheBaseline() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(harness.instance.snapshotManifest.currentID == harness.baseline.id)
    }

    @Test("A force stop returns an ephemeral VM to its baseline")
    func forceStopRevertsToTheBaseline() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.forceStop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
    }

    @Test("A guest shutting itself down returns an ephemeral VM to its baseline")
    func guestPowerOffRevertsToTheBaseline() async throws {
        let harness = try await makeHarness()

        harness.instance.handleSessionEvent(.guestDidStop)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
    }

    @Test("A VM that is not ephemeral reverts nothing when it stops")
    func nonEphemeralStopRevertsNothing() async throws {
        let harness = try await makeHarness(ephemeral: false)

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(harness.instance.snapshotManifest.currentID == harness.later.id)
    }

    @Test("A mode left on with a baseline the manifest lost reverts nothing")
    func danglingBaselineRevertsNothing() async throws {
        let harness = try await makeHarness()
        harness.instance.configuration.ephemeralBaselineSnapshotID = UUID()

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
    }

    @Test("The mode survives its own revert")
    func modeSurvivesTheRevert() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.instance.configuration.ephemeralModeEnabled)
        #expect(harness.instance.configuration.ephemeralBaselineSnapshotID == harness.baseline.id)
    }

    @Test("A baseline revert that fails surfaces the error")
    func failedBaselineRevertSurfacesTheError() async throws {
        let harness = try await makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(presenter.showError)
        // The files never landed, so the VM's state does not descend from the
        // baseline and the marker says so.
        #expect(harness.instance.snapshotManifest.currentID == harness.later.id)
    }

    // MARK: - Suspend

    @Test("Suspending keeps the session — it does not revert")
    func suspendKeepsTheSession() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.save(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.saveCallCount == 1)
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(harness.instance.status == .paused)
    }

    // MARK: - Discard Saved State

    @Test("Discarding a suspended ephemeral session reverts to the baseline")
    func discardSavedStateReverts() async throws {
        let harness = try await makeHarness(status: .paused)

        await harness.viewModel.stop(harness.instance)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(harness.instance.snapshotManifest.currentID == harness.baseline.id)
        // The plain discard path was not taken.
        #expect(harness.virtualization.stopCallCount == 0)
    }

    @Test("Force-stopping a suspended ephemeral session reverts to the baseline")
    func forceStopFromColdPausedReverts() async throws {
        let harness = try await makeHarness(status: .paused)

        await harness.viewModel.forceStopConfirmed(harness.instance)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(harness.virtualization.forceStopCallCount == 0)
    }

    @Test("A suspended VM that is not ephemeral still just discards")
    func nonEphemeralDiscardIsUnchanged() async throws {
        let harness = try await makeHarness(ephemeral: false, status: .paused)

        await harness.viewModel.stop(harness.instance)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(harness.virtualization.stopCallCount == 1)
    }

    // MARK: - Baseline protection

    @Test("The baseline cannot be deleted while the mode is on")
    func baselineIsUndeletable() async throws {
        let harness = try await makeHarness()

        #expect(!harness.viewModel.canDeleteSnapshot(harness.instance, snapshot: harness.baseline))
        #expect(harness.viewModel.canDeleteSnapshot(harness.instance, snapshot: harness.later))

        harness.viewModel.confirmDeleteSnapshot(harness.instance, snapshot: harness.baseline)
        #expect(presenter.deleteSnapshots.isEmpty)

        await harness.viewModel.deleteSnapshotConfirmed(harness.instance, snapshot: harness.baseline)
            .value
        #expect(harness.snapshots.discardedIDs.isEmpty)
        #expect(harness.instance.snapshotManifest.snapshots.count == 2)
    }

    @Test("Turning the mode off releases the baseline for deletion")
    func turningTheModeOffReleasesTheBaseline() async throws {
        let harness = try await makeHarness()
        harness.instance.configuration.applyEphemeralMode(enabled: false, baseline: nil)

        #expect(harness.viewModel.canDeleteSnapshot(harness.instance, snapshot: harness.baseline))

        await harness.viewModel.deleteSnapshotConfirmed(harness.instance, snapshot: harness.baseline)
            .value

        #expect(harness.snapshots.discardedIDs == [harness.baseline.id])
    }

    @Test("A non-baseline snapshot is still deletable while the mode is on")
    func otherSnapshotsStayDeletable() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.deleteSnapshotConfirmed(harness.instance, snapshot: harness.later)
            .value

        #expect(harness.snapshots.discardedIDs == [harness.later.id])
    }
}
