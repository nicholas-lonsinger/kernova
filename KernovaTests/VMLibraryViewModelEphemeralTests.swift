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
        /// The second ephemeral VM, present only when `secondVM` was asked for.
        let other: VMInstance?
        let otherBaseline: VMSnapshot?
    }

    /// Registers one VM's bundle, its two snapshots, and what each of them
    /// captured, and answers the pair.
    private func seedVM(
        named name: String, ephemeral: Bool, storage: MockVMStorageService,
        snapshots: MockVMSnapshotStore
    ) throws -> (config: VMConfiguration, baseline: VMSnapshot, later: VMSnapshot) {
        let baseline = VMSnapshot(
            name: "\(name) clean install", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let later = VMSnapshot(
            name: "\(name) mid-session", createdAt: Date(timeIntervalSince1970: 1_700_001_000))

        var config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
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
        return (config, baseline, later)
    }

    /// Loads the VMs through the view model — the path that wires the power-off
    /// hook — each carrying two snapshots, the older of which is its baseline.
    ///
    /// `ephemeral` decides whether the first VM's mode is on; `status` is where
    /// it rests once loaded. `secondVM` adds a second, always-ephemeral VM, for
    /// the cases that turn on the two being tracked apart.
    private func makeHarness(
        ephemeral: Bool = true, status: VMStatus = .running, secondVM: Bool = false
    ) async throws -> Harness {
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
        let snapshots = MockVMSnapshotStore()

        let first = try seedVM(
            named: "Throwaway", ephemeral: ephemeral, storage: storage, snapshots: snapshots)
        let second =
            secondVM
            ? try seedVM(named: "Sandbox", ephemeral: true, storage: storage, snapshots: snapshots)
            : nil

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
        let instance = try #require(
            viewModel.instances.first { $0.configuration.id == first.config.id })
        instance.status = status
        let other = second.flatMap { seeded in
            viewModel.instances.first { $0.configuration.id == seeded.config.id }
        }

        return Harness(
            viewModel: viewModel, storage: storage, virtualization: virtualization,
            snapshots: snapshots, instance: instance, baseline: first.baseline,
            later: first.later, other: other, otherBaseline: second?.baseline)
    }

    /// Awaits every revert a power-off started, if it started any.
    private func settleEphemeralRevert(_ harness: Harness) async {
        await harness.viewModel.waitForRevertsToSettle()
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

    @Test("A power-off registers its revert before it returns")
    func powerOffRegistersTheRevertSynchronously() async throws {
        let harness = try await makeHarness()

        harness.instance.handleSessionEvent(.guestDidStop)

        // No await in between: the termination gate reads this on the very next
        // main-actor turn, so a revert registered only once its task body ran
        // would let a quit exit through the copy.
        #expect(harness.viewModel.hasRevertInFlight)
        #expect(harness.viewModel.hasUninterruptibleWork)

        await settleEphemeralRevert(harness)

        #expect(!harness.viewModel.hasRevertInFlight)
        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
    }

    @Test("Two ephemeral VMs powering off together each return to their own baseline")
    func twoVMsRevertToTheirOwnBaselines() async throws {
        let harness = try await makeHarness(secondVM: true)
        let other = try #require(harness.other)
        let otherBaseline = try #require(harness.otherBaseline)
        other.status = .running

        await harness.viewModel.stop(harness.instance)
        await harness.viewModel.stop(other)
        await settleEphemeralRevert(harness)

        #expect(
            Set(harness.virtualization.revertedSnapshots.map(\.id))
                == [harness.baseline.id, otherBaseline.id])
        #expect(harness.instance.snapshotManifest.currentID == harness.baseline.id)
        #expect(other.snapshotManifest.currentID == otherBaseline.id)
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
