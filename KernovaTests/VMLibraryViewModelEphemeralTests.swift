import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

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
        snapshots: MockVMBundleMachineFiles, baselineKind: VMSnapshotKind = .warm
    ) throws -> (config: VMConfiguration, baseline: VMSnapshot, later: VMSnapshot) {
        let baseline = VMSnapshot(
            name: "\(name) clean install", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: baselineKind, macAddress: nil)
        let later = VMSnapshot(
            name: "\(name) mid-session", createdAt: Date(timeIntervalSince1970: 1_700_001_000), macAddress: nil)

        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = try storage.bundleURL(for: config)
        storage.bundles[bundleURL] = config
        if ephemeral {
            var hostState = VMHostState()
            hostState.applyEphemeralMode(enabled: true, baseline: baseline.id)
            storage.hostStates[bundleURL] = hostState
        }
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
    private func makeHarness(
        ephemeral: Bool = true, phase: VMLifecyclePhase = .running(sessionID: UUID()),
        secondVM: Bool = false, baselineKind: VMSnapshotKind = .warm
    ) async throws -> Harness {
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
        let snapshots = MockVMBundleMachineFiles(files: storage.files)

        let first = try seedVM(
            named: "Throwaway", ephemeral: ephemeral, storage: storage, snapshots: snapshots,
            baselineKind: baselineKind)
        let second =
            secondVM
            ? try seedVM(named: "Sandbox", ephemeral: true, storage: storage, snapshots: snapshots)
            : nil

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
        await viewModel.loadVMs()
        let instance = try #require(
            viewModel.instances.first { $0.configuration.id == first.config.id })
        instance.activity.placeForTesting(phase)
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

    @Test("A VM with a memory-and-disks baseline rests suspended after a power-off")
    func warmBaselineRestsSuspended() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.instance.status == .suspended)
    }

    @Test("A VM with a baseline taken while stopped rests stopped after a power-off")
    func coldBaselineRestsStopped() async throws {
        let harness = try await makeHarness(baselineKind: .cold)

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(harness.instance.status == .stopped)
    }

    @Test("A power-off registers its revert before it returns")
    func powerOffRegistersTheRevertSynchronously() async throws {
        let harness = try await makeHarness()

        harness.instance.handleSessionEvent(.guestDidStop)

        // No await in between: the termination gate reads this on the very next
        // main-actor turn, so a revert registered only once its task body ran
        // would let a quit exit through the copy.
        #expect(harness.viewModel.library.hasRevertInFlight)
        #expect(harness.viewModel.quitMustWaitOut)
        #expect(harness.viewModel.hasUninterruptibleWork)

        await settleEphemeralRevert(harness)

        #expect(!harness.viewModel.quitMustWaitOut)
        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
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

    @Test("R4: a power-off during an operation reverts only once the operation rests the VM, in that same step")
    func powerOffDuringAnOperationRevertsAtItsEnd() async throws {
        let harness = try await makeHarness()
        let instance = harness.instance
        let session = try #require(instance.liveSessionID)
        let gate = GatedStep()
        let outcome = try instance.activity.launch(.deletingSnapshot) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        try await gate.waitUntilEntered()

        // Wrapped, not replaced: the library's own hook is what answers the
        // revert, and the wrapper sees the VM before the hook and right after
        // the step's drain admits what it answered.
        let observed = PowerOffObservation()
        let revertOnPowerOff = instance.activity.onPoweredOff
        instance.activity.onPoweredOff = {
            observed.before = instance.phase
            observed.count += 1
            return (revertOnPowerOff?() ?? []).map { owed in
                observed.ranks.append(owed.rank)
                return VMFollowUp(scope: owed.scope, rank: owed.rank, outcome: owed.outcome) {
                    try owed.admit($0)
                    observed.after = instance.phase
                }
            }
        }

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        // The operation keeps the VM; nothing asks for the revert yet.
        #expect(instance.phase.operation?.kind == .deletingSnapshot)
        #expect(observed.count == 0)
        #expect(!harness.viewModel.library.hasRevertInFlight)

        gate.release()
        try await outcome.value()

        #expect(observed.count == 1)
        #expect(observed.before == .stopped)
        #expect(observed.ranks == [.restoration])
        #expect(
            observed.after?.operation?.kind
                == .bringUp(.reverting(snapshotID: harness.baseline.id, resumesAfter: false)))
        await settleEphemeralRevert(harness)
        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
    }

    @Test("Two ephemeral VMs powering off together each return to their own baseline")
    func twoVMsRevertToTheirOwnBaselines() async throws {
        let harness = try await makeHarness(secondVM: true)
        let other = try #require(harness.other)
        let otherBaseline = try #require(harness.otherBaseline)
        other.activity.placeForTesting(.running(sessionID: UUID()))

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
        harness.viewModel.library.editHostState(of: harness.instance) {
            $0.ephemeralBaselineSnapshotID = UUID()
        }

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
    }

    @Test("The mode survives its own revert")
    func modeSurvivesTheRevert() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.instance.hostState.ephemeralModeEnabled)
        #expect(harness.instance.hostState.ephemeralBaselineSnapshotID == harness.baseline.id)
    }

    @Test("A power-off takes back the settings edited since the baseline, and no host state")
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
        let editedHostState = instance.hostState

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

    @Test("A baseline whose settings can't be read fails the revert under its own title, leaving the VM stopped")
    func unreadableBaselineRevertIsTitled() async throws {
        let harness = try await makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotConfigurationUnreadable

        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(presenter.errorTitle == "Couldn\u{2019}t Revert to the Snapshot")
        #expect(presenter.errorMessage == VMSnapshotError.snapshotConfigurationUnreadable.errorDescription)
        #expect(harness.instance.status == .stopped)
        #expect(harness.instance.snapshotManifest.currentID == harness.later.id)
    }

    @Test("Start from the app is refused, under its own title, while the baseline's settings can't be read")
    func startRefusedWhileTheBaselineIsUnreadable() async throws {
        let harness = try await makeHarness(phase: .stopped)
        let instance = harness.instance
        let config = VMConfiguration(name: "Throwaway", guestOS: .linux, bootMode: .efi)
        harness.storage.files.setSnapshotConfiguration(config, id: harness.later.id, at: instance.bundleURL)
        harness.storage.files.setData(
            Data("not json".utf8),
            atRelativePath: VMBundleLayout.snapshotConfigRelativePath(id: harness.baseline.id),
            in: instance.bundleURL)

        await harness.viewModel.start(instance)

        #expect(presenter.errorTitle == "Couldn\u{2019}t Start \u{201C}Throwaway\u{201D}")
        #expect(presenter.errorMessage == VMCommandCore.ephemeralBaselineUnreadableMessage)
        #expect(instance.status == .stopped)
        #expect(instance.unreadableFiles.map(\.snapshotID) == [harness.baseline.id])

        // Readable again, the same click starts it.
        harness.storage.files.setSnapshotConfiguration(
            config, id: harness.baseline.id, at: instance.bundleURL)
        await harness.viewModel.start(instance)
        try await waitForChange { instance.status == .running }
    }

    // MARK: - Suspend

    @Test("Suspending keeps the session — it does not revert")
    func suspendKeepsTheSession() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.save(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.saveCallCount == 1)
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(harness.instance.status == .suspended)
    }

    // MARK: - Discard Saved State

    @Test("A Stop aimed at a suspended ephemeral session asks before discarding it")
    func discardSavedStateAsksBeforeReverting() async throws {
        let harness = try await makeHarness(phase: .suspended)

        // Nothing to shut down: the revert deletes the suspended session and
        // rolls the disks back, so it takes the same consent the force path does.
        await harness.viewModel.stop(harness.instance)

        #expect(presenter.forceStopInstances.map(\.id) == [harness.instance.id])
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(harness.instance.snapshotManifest.currentID == harness.later.id)
        #expect(harness.virtualization.stopCallCount == 0)
    }

    @Test("A confirmed discard of a suspended ephemeral session reverts to the baseline")
    func discardSavedStateReverts() async throws {
        let harness = try await makeHarness(phase: .suspended)

        await harness.viewModel.forceStop(harness.instance)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(harness.instance.snapshotManifest.currentID == harness.baseline.id)
        // Neither plain discard path was taken.
        #expect(harness.virtualization.stopCallCount == 0)
        #expect(harness.virtualization.forceStopCallCount == 0)
    }

    @Test("Discarding a suspended session still routes through a baseline taken while stopped")
    func discardSavedStateRevertsToAColdBaseline() async throws {
        let harness = try await makeHarness(phase: .suspended, baselineKind: .cold)

        await harness.viewModel.forceStop(harness.instance)

        #expect(harness.virtualization.revertedSnapshots == [harness.baseline])
        #expect(harness.instance.status == .stopped)
        #expect(harness.virtualization.stopCallCount == 0)
    }

    @Test("A suspended VM that is not ephemeral is asked about too, then just discards")
    func nonEphemeralDiscardIsUnchanged() async throws {
        let harness = try await makeHarness(ephemeral: false, phase: .suspended)

        // The session a plain discard deletes is no less lost for the VM not
        // being ephemeral, so the consent is the same.
        await harness.viewModel.stop(harness.instance)

        #expect(presenter.forceStopInstances.map(\.id) == [harness.instance.id])
        #expect(harness.virtualization.stopCallCount == 0)

        await harness.viewModel.forceStop(harness.instance)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        // A discard terminates nothing: there is no guest.
        #expect(harness.virtualization.forceStopCallCount == 0)
        #expect(!harness.instance.hasSaveFile)
        #expect(harness.instance.phase == .stopped)
    }

    // MARK: - Baseline delete

    @Test("The baseline's delete is offered while the VM runs")
    func baselineDeleteIsOfferedWhileRunning() async throws {
        let harness = try await makeHarness()

        harness.viewModel.requestDeleteSnapshot(harness.instance, snapshot: harness.baseline)

        #expect(presenter.deleteSnapshots == [harness.baseline])
    }

    /// The baseline confirmation's two steps, through the verbs automation
    /// takes one at a time: the mode off, then the delete. Ephemeral Mode is
    /// read at power-off, so the session left running keeps its changes.
    @Test(
        "Confirming the baseline's delete turns the mode off, then deletes it; a running session's power-off reverts nothing",
        arguments: [VMLifecyclePhase.running(sessionID: UUID()), .stopped])
    func confirmedBaselineDeleteTurnsTheModeOffFirst(phase: VMLifecyclePhase) async throws {
        let harness = try await makeHarness(phase: phase)

        await harness.viewModel.deleteSnapshot(
            harness.instance, snapshot: harness.baseline, turningOffEphemeralMode: true
        ).value

        #expect(!presenter.showError)
        #expect(harness.snapshots.discardedIDs == [harness.baseline.id])
        #expect(harness.instance.snapshotManifest.snapshots.map(\.id) == [harness.later.id])
        #expect(!harness.instance.hostState.ephemeralModeEnabled)
        #expect(
            harness.storage.files.hostState(at: harness.instance.bundleURL)?.ephemeralModeEnabled
                == false)
        #expect(harness.instance.phase == phase)

        guard phase != .stopped else { return }
        await harness.viewModel.stop(harness.instance)
        await settleEphemeralRevert(harness)

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(!presenter.showError)
        #expect(harness.instance.snapshotManifest.currentID == harness.later.id)
    }

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

    @Test("A mode-off write that fails deletes nothing")
    func failedModeOffDeletesNothing() async throws {
        let harness = try await makeHarness(phase: .stopped)
        harness.storage.files.setReplaceError(
            CocoaError(.fileWriteNoPermission), for: VMBundleLayout.hostStateRelativePath)

        await harness.viewModel.deleteSnapshot(
            harness.instance, snapshot: harness.baseline, turningOffEphemeralMode: true
        ).value

        #expect(presenter.showError)
        #expect(harness.instance.ephemeralBaselineSnapshot?.id == harness.baseline.id)
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

    @Test("A non-baseline snapshot deletes as before while the mode is on, and leaves it on")
    func otherSnapshotsStayDeletable() async throws {
        let harness = try await makeHarness()

        await harness.viewModel.deleteSnapshot(
            harness.instance, snapshot: harness.later, turningOffEphemeralMode: false
        ).value

        #expect(harness.snapshots.discardedIDs == [harness.later.id])
        #expect(harness.instance.ephemeralBaselineSnapshot?.id == harness.baseline.id)
    }
}

/// The VM before the power-off hook and right after its revert was admitted,
/// the ranks the hook answered, and how often it fired.
@MainActor
private final class PowerOffObservation {
    var before: VMLifecyclePhase?
    var after: VMLifecyclePhase?
    var ranks: [VMFollowUp.Rank] = []
    var count = 0
}
