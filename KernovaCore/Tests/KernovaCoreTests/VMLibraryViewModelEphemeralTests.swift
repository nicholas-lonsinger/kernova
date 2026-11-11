import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The Ephemeral Mode policy: what a power-off does, what a suspend doesn't,
/// and what the baseline is protected from.
@Suite("VMLibraryViewModel Ephemeral Mode Tests", .serialized, .caseScoped)
@MainActor
struct VMLibraryViewModelEphemeralTests {
    private let presenter = MockVMLibraryPresenting()
    private let preferences = makeTestPreferences()

    private struct Harness {
        let viewModel: VMLibraryViewModel
        let storage: MockVMStorageService
        let virtualization: MockVirtualizationService
        let snapshots: MockVMBundleMachineFiles
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
        snapshots: MockVMBundleMachineFiles, baselineKind: VMSnapshotKind = .warm,
        unsettled: Bool = false
    ) throws -> (config: VMConfiguration, baseline: VMSnapshot, later: VMSnapshot) {
        let baseline = VMSnapshot(
            name: "\(name) clean install", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: baselineKind, macAddress: nil)
        let later = VMSnapshot(
            name: "\(name) mid-session", createdAt: Date(timeIntervalSince1970: 1_700_001_000), macAddress: nil)

        let config = VMConfiguration(
            name: name, guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let bundleURL = try storage.bundleURL(for: config)
        storage.setConfiguration(config, at: bundleURL)
        var hostState = VMHostState(hasUnsettledSession: unsettled)
        if ephemeral { hostState.applyEphemeralMode(enabled: true, baseline: baseline.id) }
        storage.setHostState(hostState, at: bundleURL)
        storage.files.setManifest(
            VMSnapshotManifest(snapshots: [baseline, later], currentID: later.id), at: bundleURL)
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
    /// `ephemeral` decides whether the first VM's mode is on; `phase` is where
    /// it rests once loaded. `secondVM` adds a second, always-ephemeral VM, for
    /// the cases that turn on the two being tracked apart.
    ///
    /// With `unsettled`, the first VM's last session ended unsettled — what a
    /// copy of Kernova dying under it leaves — and the VM is left where the
    /// load left it; `heldElsewhere` has another copy hold its bundle through
    /// the load.
    private func makeHarness(
        ephemeral: Bool = true, phase: VMLifecyclePhase = .running(sessionID: UUID()),
        secondVM: Bool = false, baselineKind: VMSnapshotKind = .warm,
        unsettled: Bool = false, heldElsewhere: Bool = false
    ) async throws -> Harness {
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
        let snapshots = MockVMBundleMachineFiles(files: storage.files)

        let first = try seedVM(
            named: "Throwaway", ephemeral: ephemeral, storage: storage, snapshots: snapshots,
            baselineKind: baselineKind, unsettled: unsettled)
        if heldElsewhere { storage.files.holdElsewhere(try storage.bundleURL(for: first.config)) }
        let second =
            secondVM
            ? try seedVM(named: "Sandbox", ephemeral: true, storage: storage, snapshots: snapshots)
            : nil

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
        await viewModel.loadVMs()
        let instance = try #require(
            viewModel.instances.first { $0.configuration.id == first.config.id })
        if !unsettled { instance.activity.placeForTesting(phase) }
        // A suspension is a slot on disk, not a phase name: every predicate the
        // discard paths read asks the file.
        if phase == .suspended { try VMInstanceFixture.writeSaveFile(for: instance) }
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
        await harness.viewModel.library.waitForRevertsToSettle()
    }

    // MARK: - Power-off

    @Test("A graceful stop returns an ephemeral VM to its baseline, resting suspended with the mode kept")
    func stopRevertsToTheBaseline() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(harness.instance.snapshotManifest.currentID == harness.baseline.id)
        #expect(harness.instance.status == .suspended)
        #expect(harness.instance.hostState.ephemeralModeEnabled)
        #expect(harness.instance.hostState.ephemeralBaselineSnapshotID == harness.baseline.id)
    }

    @Test("A power-off during the termination still admits the baseline revert, which the quit waits out")
    func powerOffDuringTerminationReverts() async throws {
        let harness = try await makeHarness()
        harness.viewModel.beginTermination()

        harness.instance.handleSessionEvent(.guestDidStop)

        #expect(harness.viewModel.library.hasRevertInFlight)
        #expect(harness.viewModel.quitMustWaitOut)
        await settleEphemeralRevert(harness)
        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
    }

    @Test("A power-off takes back the settings edited since the baseline, and no host state but the session it settles")
    func revertKeepsTheHostState() async throws {
        let harness = try await makeHarness()
        let instance = harness.instance
        let capturedSharing = instance.configuration.clipboardSharingEnabled
        try harness.viewModel.library.updateSettings(
            of: instance, as: [.liveKeys, .hostPresentation, .observations],
            configuration: { $0.clipboardSharingEnabled = !capturedSharing },
            hostState: {
                $0.startsAutomaticallyOnLaunch = true
                $0.displayPreference = .fullscreen
                $0.lastFullscreenDisplayID = 4_280_803_137
                $0.agentInstallNudgeDismissed = true
                $0.tags = [UUID()]
            })
        // The revert settles the session it ends, and takes back no other
        // host state.
        var editedHostState = instance.hostState
        editedHostState.hasUnsettledSession = false

        await harness.viewModel.stop(instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(instance.configuration.clipboardSharingEnabled == capturedSharing)
        #expect(instance.hostState == editedHostState)
        #expect(harness.storage.hostStates[instance.bundleURL] == editedHostState)
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

    // MARK: - Launch

    @Test("A VM whose last session ended unsettled reverts as the library loads, and the revert settles it")
    func launchRevertsAnUnsettledSession() async throws {
        let harness = try await makeHarness(unsettled: true)

        #expect(harness.instance.status == .restoring)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(!harness.instance.hostState.hasUnsettledSession)
        #expect(harness.instance.status == .suspended)
        #expect(!harness.instance.activity.holdsRunLock)
    }

    // MARK: - Baseline delete

    @Test("A delete that fails after the mode turned off leaves the mode off and the snapshot listed")
    func failedDeleteLeavesTheModeOffAndTheSnapshot() async throws {
        let harness = try await makeHarness(phase: .stopped)
        harness.storage.files.setReplaceError(
            CocoaError(.fileWriteNoPermission), for: VMBundleLayout.snapshotManifestRelativePath)

        await harness.viewModel.deleteSnapshot(
            harness.instance, snapshot: harness.baseline, turningOffEphemeralMode: true
        ).value

        #expect(presenter.showError)
        #expect(!harness.instance.hostState.ephemeralModeEnabled)
        #expect(
            harness.instance.snapshotManifest.snapshots.map(\.id)
                == [harness.baseline.id, harness.later.id])
        #expect(harness.snapshots.discardedIDs.isEmpty)
    }

    /// The plain confirmation was answered before the mode came to name the
    /// snapshot: the core refuses the delete, and the app asks again with the
    /// baseline's confirmation rather than reporting the refusal.
    @Test("A plain delete of a snapshot that became the baseline asks again with the baseline's confirmation")
    func plainDeleteOfTheBaselineAsksAgain() async throws {
        let harness = try await makeHarness(phase: .stopped)

        await harness.viewModel.deleteSnapshot(
            harness.instance, snapshot: harness.baseline, turningOffEphemeralMode: false
        ).value

        #expect(presenter.deleteSnapshots == [harness.baseline])
        #expect(!presenter.showError)
        #expect(harness.snapshots.discardedIDs.isEmpty)
        #expect(harness.instance.ephemeralBaselineSnapshot?.id == harness.baseline.id)
    }
}
