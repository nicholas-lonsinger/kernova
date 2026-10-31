import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The unsettled-session marker (``VMHostState/hasUnsettledSession``): what
/// sets it, what settles it, and the one rule a session found ended unsettled
/// answers to — an Ephemeral VM's baseline revert, which every request
/// carrying the guest's files forward waits out.
@Suite("Ephemeral Session Settlement Tests", .serialized, .caseScoped)
@MainActor
struct EphemeralSessionSettlementTests {
    private let preferences = makeTestPreferences()

    private struct Probe: Error {}

    /// A VM with a `kind` baseline snapshot and a cold `other` one, in
    /// Ephemeral Mode on the baseline when `ephemeral`, its last session
    /// unsettled when `unsettled`, placed at `phase` — a live or suspended one
    /// as a bring-up or a suspend leaves it.
    private func makeVM(
        in harness: WiredCommandCore, baseline kind: VMSnapshotKind = .warm,
        other otherKind: VMSnapshotKind = .cold, ephemeral: Bool = true, unsettled: Bool = false,
        phase: VMLifecyclePhase = .stopped, mutate: (inout VMConfiguration) -> Void = { _ in }
    ) throws -> (instance: VMInstance, baseline: VMSnapshot, other: VMSnapshot) {
        // The newer of the two, so it is the one an enable pins.
        let baseline = VMSnapshot(
            name: "Clean", createdAt: Date(timeIntervalSince1970: 1_700_001_000), kind: kind,
            macAddress: nil)
        let other = VMSnapshot(
            name: "Other", createdAt: Date(timeIntervalSince1970: 1_700_000_000), kind: otherKind,
            macAddress: nil)
        var hostState = ephemeral ? VMHostState.ephemeral(baseline: baseline.id) : VMHostState()
        hostState.hasUnsettledSession = unsettled
        let instance = RegisteredVMInstanceFixture.register(
            name: "Throwaway", phase: .stopped, guestOS: .linux, snapshots: [baseline, other],
            library: harness.library, preferences: preferences, hostState: hostState, mutate: mutate)
        // What each snapshot's own config.json holds, so a revert reads it back
        // and a bring-up after it finds the baseline readable.
        for snapshot in [baseline, other] {
            harness.machineFiles.setCapturedConfiguration(instance.configuration, for: snapshot.id)
            harness.storage.files.setSnapshotConfiguration(
                instance.configuration, id: snapshot.id, at: instance.bundleURL)
        }
        instance.activity.refreshFromBundle()
        if phase == .suspended { try VMInstanceFixture.writeSaveFile(for: instance) }
        if phase != .stopped { instance.activity.placeForTesting(phase) }
        return (instance, baseline, other)
    }

    // MARK: - Setting

    @Test("A start marks the session unsettled before the guest starts, from the disks or the slot")
    func startMarksTheSessionFirst() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (cold, _, _) = try makeVM(in: harness, ephemeral: false)
        try await harness.core.start(.id(cold.id), recovery: false, consent: .none)
        #expect(virtualization.lastStartRoute == .coldBoot)
        #expect(virtualization.hostStateAtStart?.hasUnsettledSession == true)

        let other = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (suspended, _, _) = try makeVM(in: other, ephemeral: false, phase: .suspended)
        try await other.core.resume(.id(suspended.id), consent: .none)
        #expect(virtualization.lastStartRoute == .restoredSavedState)
        #expect(virtualization.hostStateAtStart?.hasUnsettledSession == true)
    }

    @Test("A revert marks the session unsettled before its first swap, and settles it once its files land")
    func revertMarksBeforeItsSwapsAndSettlesAfter() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, other) = try makeVM(in: harness, ephemeral: false)

        try await harness.core.revertToSnapshot(
            .id(instance.id), snapshot: other.id, consent: Consent([.revertToSnapshot]))

        #expect(virtualization.hostStateAtInstall?.hasUnsettledSession == true)
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("A live warm revert that resumes keeps its new session unsettled")
    func resumingRevertKeepsTheSessionUnsettled() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(
            in: harness, ephemeral: false, phase: .running(sessionID: UUID()))

        try await harness.core.revertToSnapshot(
            .id(instance.id), snapshot: baseline.id, consent: Consent([.revertToSnapshot]))

        #expect(virtualization.hostStateAtInstall?.hasUnsettledSession == true)
        #expect(instance.hasLiveVirtualMachine)
        #expect(instance.hostState.hasUnsettledSession)
    }

    @Test("A resume whose mark cannot be written fails without the guest executing, keeping the slot")
    func failedMarkFailsTheBringUp() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, _) = try makeVM(in: harness, phase: .suspended)
        harness.storage.files.setReplaceError(
            CocoaError(.fileWriteNoPermission), for: VMBundleLayout.hostStateRelativePath)

        await #expect(throws: (any Error).self) {
            try await harness.core.resume(.id(instance.id), consent: .none)
        }

        #expect(virtualization.guestExecutionCount == 0)
        #expect(!instance.hasLiveVirtualMachine)
        #expect(instance.hasSaveFile)
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test(
        "A resume whose restore fails keeps its parked session; neither the launch nor a resume reverts it"
    )
    func failedResumeKeepsTheParkedSession() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.restoreError = Probe()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, _) = try makeVM(in: harness, phase: .suspended)

        await #expect(throws: (any Error).self) {
            try await harness.core.resume(.id(instance.id), consent: .none)
        }
        #expect(instance.hasSaveFile)
        #expect(!instance.hostState.hasUnsettledSession)

        instance.activity.settleUnsettledSessionAtLaunch()
        virtualization.restoreError = nil
        try await harness.core.resume(.id(instance.id), consent: .none)

        #expect(virtualization.revertCallCount == 0)
        #expect(virtualization.lastStartRoute == .restoredSavedState)
        #expect(instance.status == .running)
    }

    @Test(
        "A start failing before the guest executes leaves it settled, so a revert to another snapshot holds"
    )
    func failedStartKeepsAnotherSnapshot() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, other) = try makeVM(in: harness)
        try await harness.core.revertToSnapshot(
            .id(instance.id), snapshot: other.id, consent: Consent([.revertToSnapshot]))

        virtualization.startError = Probe()
        await #expect(throws: (any Error).self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        #expect(!instance.hostState.hasUnsettledSession)

        virtualization.startError = nil
        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)

        #expect(virtualization.revertedSnapshots.map(\.id) == [other.id])
        #expect(virtualization.lastStartRoute == .coldBoot)
    }

    // MARK: - Settling

    @Test("An Ephemeral VM's session end reverts it, and the revert's landing settles the session")
    func baselineRevertSettlesTheSession() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: UUID()))
        #expect(instance.hostState.hasUnsettledSession)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .none)
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("A revert that fails once it has marked the session leaves it unsettled")
    func failedRevertLeavesTheSessionUnsettled() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, other) = try makeVM(in: harness, ephemeral: false)
        // Fails the write that follows the files landing, ahead of the settle.
        harness.storage.files.setReplaceError(
            CocoaError(.fileWriteNoPermission), for: VMBundleLayout.snapshotManifestRelativePath)

        await #expect(throws: (any Error).self) {
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: other.id, consent: Consent([.revertToSnapshot]))
        }

        #expect(instance.hostState.hasUnsettledSession)
    }

    @Test("A session of a VM not in Ephemeral Mode is settled as it ends, and nothing reverts")
    func nonEphemeralSessionEndSettles() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let session = UUID()
        let (instance, _, _) = try makeVM(
            in: harness, ephemeral: false, phase: .running(sessionID: session))

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)

        #expect(instance.phase == .stopped)
        #expect(!instance.hostState.hasUnsettledSession)
        #expect(virtualization.revertCallCount == 0)
    }

    @Test("A suspend whose session ends under the write is a session end, which reverts an Ephemeral VM")
    func suspendLosingItsSessionReverts() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestStopsDuringSave = true
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: UUID()))

        try await harness.core.suspend(.id(instance.id), consent: .all)
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("A live revert to a warm snapshot whose resume fails leaves that snapshot to resume")
    func failedResumeAfterARevertResumesThatSnapshot() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.resumeError = Probe()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, other) = try makeVM(
            in: harness, other: .warm, phase: .running(sessionID: UUID()))

        await #expect(throws: (any Error).self) {
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: other.id, consent: .all)
        }
        #expect(!instance.hostState.hasUnsettledSession)

        virtualization.resumeError = nil
        try await harness.core.resume(.id(instance.id), consent: .none)

        #expect(virtualization.revertedSnapshots.map(\.id) == [other.id])
        #expect(virtualization.lastStartRoute == .restoredSavedState)
        #expect(instance.snapshotManifest.currentID == other.id)
    }

    @Test("A suspend parks the session, settling it, and nothing reverts")
    func suspendSettlesTheSession() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, _) = try makeVM(in: harness, phase: .running(sessionID: UUID()))

        try await harness.core.suspend(.id(instance.id), consent: .all)

        #expect(instance.phase == .suspended)
        #expect(!instance.hostState.hasUnsettledSession)
        #expect(virtualization.revertCallCount == 0)
    }

    @Test("A user's revert of a running Ephemeral VM settles its session, and no baseline revert follows")
    func userRevertSettlesTheSession() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, other) = try makeVM(in: harness, phase: .running(sessionID: UUID()))

        try await harness.core.revertToSnapshot(
            .id(instance.id), snapshot: other.id, consent: .all)
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.revertedSnapshots.map(\.id) == [other.id])
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("A user's revert at rest to another snapshot boots that snapshot at the next start")
    func revertToAnotherSnapshotBootsIt() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, other) = try makeVM(in: harness)

        try await harness.core.revertToSnapshot(
            .id(instance.id), snapshot: other.id, consent: Consent([.revertToSnapshot]))
        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)

        #expect(virtualization.revertedSnapshots.map(\.id) == [other.id])
        #expect(virtualization.lastStartRoute == .coldBoot)
        #expect(instance.snapshotManifest.currentID == other.id)
    }

    // MARK: - Restart

    /// How the session a Restart waits on ends.
    enum RestartedSessionEnd: CaseIterable, Sendable {
        case shutdownAsked, guestShutsItselfDown, guestFails
    }

    @Test(
        "A Restart keeps an Ephemeral VM's session and boots it, however the session it waits on ends",
        arguments: RestartedSessionEnd.allCases)
    func restartKeepsTheSession(end: RestartedSessionEnd) async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = end != .shutdownAsked
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let session = UUID()
        let (instance, _, _) = try makeVM(in: harness, phase: .running(sessionID: session))

        let restart = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), timeout: nil, consent: .none)
        }
        try await virtualization.stopRequested.wait { virtualization.stopCallCount == 1 }
        switch end {
        case .shutdownAsked:
            break
        case .guestShutsItselfDown:
            instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        case .guestFails:
            instance.activity.deliverSessionEvent(.didStopWithError(Probe()), from: session)
        }
        try await restart.value

        #expect(virtualization.revertCallCount == 0)
        // The disks the session left, booted cold — not the baseline's saved
        // state a revert installs.
        #expect(virtualization.lastStartRoute == .coldBoot)
        #expect(instance.status == .running)
        // Carried into the session the boot brought up, whose end settles it.
        #expect(instance.hostState.hasUnsettledSession)
    }

    /// A stop someone asks for while a Restart waits.
    enum StopDuringRestart: CaseIterable, Sendable { case graceful, force }

    @Test(
        "A Stop or Force Stop while a Restart waits cancels it: nothing boots, and the VM reverts",
        arguments: StopDuringRestart.allCases)
    func stopCancelsAWaitingRestart(stop: StopDuringRestart) async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let session = UUID()
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: session))

        let restart = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), timeout: nil, consent: .none)
        }
        try await virtualization.stopRequested.wait { virtualization.stopCallCount == 1 }
        // The prompt a Force Stop asks with names the baseline it returns to.
        #expect(VMCommandCore.forceStopPrompt(instance).message.contains(baseline.name))
        switch stop {
        case .graceful:
            try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .none)
            #expect(!instance.activity.liveSessionContinues)
            // The guest honours the request: the end of a session no restart
            // waits on any more.
            instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        case .force:
            try await harness.core.stop(.id(instance.id), disposition: .force, consent: .all)
        }

        let error = try await #require(throws: CommandError.self) { try await restart.value }
        guard case .operationFailed(.restart, _, let message, _) = error else {
            Issue.record("Expected the restart to report its cancellation, got \(error)")
            return
        }
        #expect(message.contains("was stopped while it restarted"))
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.startCallCount == 0)
        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("Only a continuation's own admission carries the ended session: another start in its step reverts first")
    func onlyTheContinuationCarriesTheSession() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let session = UUID()
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: session))
        // Admitted in the step the continuation is, but resolving an outcome
        // of its own rather than the one owed to the session's end.
        let other = VMOutcome()
        let continuation = VMFollowUp(scope: .vm, rank: .ordinary, request: .start(recovery: false)) {
            _ in try harness.core.startNow(instance, policy: .command(.unavailable), resolving: other)
        }
        instance.activity.follow(continuation, continuing: session)

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        try await other.value()

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        // The baseline's saved state the revert installed, not the session's disks.
        #expect(virtualization.lastStartRoute == .restoredSavedState)
        #expect(instance.status == .running)
    }

    @Test("A Stop after a Restart reverts the Ephemeral VM to its baseline")
    func stopAfterARestartReverts() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: UUID()))

        try await harness.core.restart(.id(instance.id), timeout: nil, consent: .none)
        #expect(virtualization.revertCallCount == 0)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .none)
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("A Restart whose deadline passes with the session live leaves its end to revert as a Stop's does")
    func timedOutRestartLeavesTheEndToRevert() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let clock = GatedEngineClock()
        let harness = WiredCommandCore(
            virtualization: virtualization, preferences: preferences, clock: clock)
        let session = UUID()
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: session))

        let restart = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), timeout: 30, consent: .none)
        }
        // The parked sleep is the power-off deadline: the restart is waiting,
        // its boot owed to the session's end.
        try await clock.sleepRequested.wait { !clock.parked.isEmpty }
        #expect(virtualization.stopCallCount == 1)
        #expect(instance.activity.liveSessionContinues)

        clock.release(try #require(clock.parked.first))
        let error = try await #require(throws: CommandError.self) { try await restart.value }
        guard case .timedOut(_, .restart, _) = error else {
            Issue.record("Expected the restart's timeout, got \(error)")
            return
        }
        #expect(!instance.activity.liveSessionContinues)

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(virtualization.startCallCount == 0)
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("A Restart whose boot is refused at the power-off leaves the session to revert as a Stop's does")
    func refusedRestartBootReverts() async throws {
        preferences.allowsDuplicateMachineIDOverride = true
        let identity = Data([7, 7, 7])
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let session = UUID()
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: session)) {
            $0.genericMachineIdentifierData = identity
        }
        let twin = RegisteredVMInstanceFixture.register(
            name: "Twin", phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences
        ) { $0.genericMachineIdentifierData = identity }

        let restart = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), timeout: nil, consent: .none)
        }
        try await virtualization.stopRequested.wait { virtualization.stopCallCount == 1 }
        // Started beside the restarting VM while it waits, so the boot — which
        // nobody can be asked about — meets the shared identity.
        try await harness.core.start(
            .id(twin.id), recovery: false, consent: Consent([.startBesideSharedMachineIdentity]))
        instance.activity.deliverSessionEvent(.guestDidStop, from: session)

        await #expect(throws: (any Error).self) { try await restart.value }
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        // The twin's start alone.
        #expect(virtualization.startCallCount == 1)
        #expect(!instance.hasLiveVirtualMachine)
        #expect(!instance.hostState.hasUnsettledSession)
    }

    @Test("A Restart whose boot fails before the guest executes leaves the session to revert as a Stop's does")
    func failedRestartBootReverts() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let session = UUID()
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: session))

        let restart = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), timeout: nil, consent: .none)
        }
        try await virtualization.stopRequested.wait { virtualization.stopCallCount == 1 }
        virtualization.startError = Probe()
        instance.activity.deliverSessionEvent(.guestDidStop, from: session)

        await #expect(throws: (any Error).self) { try await restart.value }
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.startCallCount == 1)
        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(!instance.hasLiveVirtualMachine)
        #expect(!instance.hostState.hasUnsettledSession)
    }

    // MARK: - Session end

    @Test("A baseline revert that fails at a session end is tried once, and the session stays unsettled")
    func failingRevertAtSessionEndDoesNotLoop() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let session = UUID()
        let (instance, _, _) = try makeVM(in: harness, phase: .running(sessionID: session))

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.revertCallCount == 1)
        #expect(instance.activity.isAtRest)
        #expect(instance.hostState.hasUnsettledSession)
        #expect(!instance.activity.holdsRunLock)
    }

    // MARK: - A fresh lock take

    @Test("A start finding an Ephemeral VM's session unsettled reverts it first, then starts on the baseline")
    func startOnAnUnsettledVMRevertsFirst() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, unsettled: true)

        try await harness.core.start(.id(instance.id), recovery: false, consent: .none)

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(virtualization.startCallCount == 1)
        #expect(virtualization.lastStartRoute == .restoredSavedState)
        #expect(instance.status == .running)
    }

    @Test("A start whose owed revert fails is refused, booting nothing")
    func failedOwedRevertRefusesTheStart() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, unsettled: true)

        await #expect {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        } throws: { error in
            guard case .operationFailed(.start, _, let message, _) = error as? CommandError else {
                return false
            }
            return message.contains(baseline.name)
        }

        #expect(virtualization.startCallCount == 0)
        #expect(!instance.hasLiveVirtualMachine)
        #expect(instance.hostState.hasUnsettledSession)
    }

    @Test("An owed revert refused at admission refuses the request and lets go of the lock")
    func refusedOwedRevertLetsGoOfTheLock() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, _, _) = try makeVM(in: harness, unsettled: true)
        instance.activity.onUnsettledSession = {
            [VMFollowUp(scope: .vm, rank: .restoration) { _ in throw Probe() }]
        }

        await #expect(throws: (any Error).self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }

        #expect(!instance.activity.holdsRunLock)
        #expect(virtualization.startCallCount == 0)
        #expect(instance.hostState.hasUnsettledSession)
    }

    // MARK: - Waiting

    @Test("A capture finding an Ephemeral VM's session unsettled waits out the revert and captures the baseline")
    func captureWaitsOutAnOwedRevert() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, unsettled: true)

        let captured = try await harness.core.takeSnapshot(
            .id(instance.id), name: "After", notes: "", consent: .all)

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        // Suspended on the warm baseline's saved state, which the capture took.
        #expect(captured.kind == VMSnapshotKind.warm.rawValue)
    }

    @Test("A clone finding an Ephemeral VM's session unsettled waits out the revert and copies the baseline")
    func cloneWaitsOutAnOwedRevert() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, unsettled: true)
        // What the baseline captured differs from what the session left.
        var captured = instance.configuration
        captured.cpuCount = 1
        harness.machineFiles.setCapturedConfiguration(captured, for: baseline.id)

        let summary = try await harness.core.clone(
            .id(instance.id), outcome: .exactCopy, consent: .all, waitForOutcome: true)

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        let clone = try #require(harness.library.instances.first { $0.id == summary.id })
        // The baseline's settings and its saved state, not the session's.
        #expect(clone.configuration.cpuCount == 1)
        #expect(clone.hasSaveFile)
        #expect(!clone.hostState.hasUnsettledSession)
    }

    @Test("A live Exact Copy arrives settled")
    func liveExactCopyArrivesSettled() async throws {
        let harness = WiredCommandCore(preferences: preferences)
        let (instance, _, _) = try makeVM(in: harness, phase: .running(sessionID: UUID()))
        #expect(instance.hostState.hasUnsettledSession)

        let summary = try await harness.core.clone(
            .id(instance.id), outcome: .exactCopy, consent: .all, waitForOutcome: true)

        let clone = try #require(harness.library.instances.first { $0.id == summary.id })
        #expect(!clone.hostState.hasUnsettledSession)
        #expect(instance.hostState.hasUnsettledSession)
    }

    @Test("An imported bundle keeps its unsettled session: an Ephemeral one reverts at its first start")
    func importKeepsItsUnsettledSession() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let baseline = try importSource(in: harness, ephemeral: true)

        _ = try await harness.core.importVM(from: baseline.source, waitForOutcome: true)
        let imported = try #require(harness.library.instances.first)
        #expect(imported.hostState.hasUnsettledSession)

        try await harness.core.start(.id(imported.id), recovery: false, consent: .none)

        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(imported.status == .running)
    }

    @Test("An imported bundle not in Ephemeral Mode is settled, reverting nothing")
    func importOutOfEphemeralModeIsSettled() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let source = try importSource(in: harness, ephemeral: false)

        _ = try await harness.core.importVM(from: source.source, waitForOutcome: true)
        let imported = try #require(harness.library.instances.first)
        imported.activity.settleUnsettledSessionAtLaunch()

        #expect(!imported.hostState.hasUnsettledSession)
        #expect(virtualization.revertCallCount == 0)
    }

    /// A bundle to import whose last session ended unsettled, holding a warm
    /// snapshot — its Ephemeral baseline when `ephemeral` — answering it with
    /// the bundle.
    private func importSource(
        in harness: WiredCommandCore, ephemeral: Bool
    ) throws -> (source: URL, id: UUID) {
        let (url, config) = try TestScratchDirectory.forCase(prefix: "Imports").importSource(
            name: "Imported")
        let snapshot = VMSnapshot(name: "Clean", kind: .warm, macAddress: nil)
        let writer = VMStagedBundle.fixtureForTesting(at: url, access: CoordinatedBundleFileAccess())
        try writer.update(.snapshotManifest) { $0 = VMSnapshotManifest(snapshots: [snapshot]) }
        try writer.update(.hostState) {
            if ephemeral { $0.applyEphemeralMode(enabled: true, baseline: snapshot.id) }
            $0.hasUnsettledSession = true
        }
        let snapshotConfig = url.appendingPathComponent(
            VMBundleLayout.snapshotConfigRelativePath(id: snapshot.id))
        try FileManager.default.createDirectory(
            at: snapshotConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VMConfiguration.makeJSONEncoder().encode(config).write(to: snapshotConfig)
        harness.machineFiles.setCapturedConfiguration(config, for: snapshot.id)
        return (url, snapshot.id)
    }

    /// How the baseline revert a request meets in flight was started.
    enum RevertStart: CaseIterable, Sendable { case powerOff, stoppingSuspended }

    /// A request carrying the guest's files forward.
    enum Request: CaseIterable, Sendable { case start, resume, takeSnapshot }

    @Test(
        "A request carrying the guest's files forward waits out a baseline revert in flight, however it started",
        arguments: RevertStart.allCases, Request.allCases)
    func requestWaitsOutARevertInFlight(started: RevertStart, request: Request) async throws {
        let virtualization = SuspendingMockVirtualizationService()
        virtualization.shouldSuspendOnStart = false
        virtualization.shouldSuspendOnRevert = true
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let session = UUID()
        let (instance, _, _) = try makeVM(
            in: harness,
            phase: started == .powerOff ? .running(sessionID: session) : .suspended)

        let stop: Task<Void, any Error>?
        switch started {
        case .powerOff:
            instance.activity.deliverSessionEvent(.guestDidStop, from: session)
            stop = nil
        case .stoppingSuspended:
            stop = Task { @MainActor in
                try await harness.core.stop(.id(instance.id), disposition: .force, consent: .all)
            }
        }
        await virtualization.waitUntilSuspended()
        #expect(instance.isHeldByRevert)

        // Run to its first suspension in this turn, so what it queued is read
        // before the revert can land.
        let asked = Task.immediate { @MainActor in
            switch request {
            case .start:
                try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
            case .resume:
                try await harness.core.resume(.id(instance.id), consent: .none)
            case .takeSnapshot:
                _ = try await harness.core.takeSnapshot(.id(instance.id), name: "After", notes: "", consent: .all)
            }
        }
        // Waiting behind the revert: queued, and nothing run.
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        #expect(instance.isHeldByRevert)

        virtualization.resumeSuspended()
        try await stop?.value
        try await asked.value

        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        switch request {
        case .start, .resume: #expect(instance.status == .running)
        case .takeSnapshot: #expect(instance.snapshotManifest.snapshots.count == 3)
        }
    }

    // MARK: - Turning the mode on

    @Test(
        "Turning the mode on asks first in any state, and writes nothing unasked",
        arguments: [VMLifecyclePhase.stopped, .running(sessionID: UUID()), .suspended])
    func enablingAsks(phase: VMLifecyclePhase) throws {
        let harness = WiredCommandCore(preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, ephemeral: false, phase: phase)

        #expect {
            try harness.core.setConfiguration(
                .id(instance.id), assignments: [VMConfigurationKeyRegistry.ephemeral.assigning(true)],
                consent: .none)
        } throws: { error in
            guard case .confirmationRequired(let prompt) = error as? CommandError else { return false }
            return prompt.kind == .setEphemeralBaseline && prompt.message.contains(baseline.name)
                && prompt.title.contains(instance.name)
        }

        #expect(!instance.hostState.ephemeralModeEnabled)
    }

    @Test(
        "Confirmed, turning the mode on reverts nothing now",
        arguments: [VMLifecyclePhase.stopped, .running(sessionID: UUID()), .suspended])
    func confirmedEnableRevertsNothing(phase: VMLifecyclePhase) throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, ephemeral: false, phase: phase)

        try harness.core.setConfiguration(
            .id(instance.id), assignments: [VMConfigurationKeyRegistry.ephemeral.assigning(true)],
            consent: Consent([.setEphemeralBaseline]))

        #expect(instance.ephemeralBaselineSnapshot?.id == baseline.id)
        #expect(virtualization.revertCallCount == 0)
        #expect(!harness.library.hasRevertInFlight)
    }

    @Test("Changing the baseline asks first, and confirmed moves it and reverts nothing now")
    func baselineChangeAsks() throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, other) = try makeVM(in: harness)
        let change = [VMConfigurationKeyRegistry.ephemeralBaseline.assigning(other.id.uuidString)]

        #expect {
            try harness.core.setConfiguration(.id(instance.id), assignments: change, consent: .none)
        } throws: { error in
            guard case .confirmationRequired(let prompt) = error as? CommandError else { return false }
            return prompt.kind == .setEphemeralBaseline && prompt.message.contains(other.name)
        }
        #expect(instance.ephemeralBaselineSnapshot?.id == baseline.id)

        try harness.core.setConfiguration(
            .id(instance.id), assignments: change, consent: Consent([.setEphemeralBaseline]))

        #expect(instance.ephemeralBaselineSnapshot?.id == other.id)
        #expect(virtualization.revertCallCount == 0)
    }

    @Test("Turning the mode on by capturing a fresh baseline asks nothing")
    func enablingByCapturingAsksNothing() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let instance = RegisteredVMInstanceFixture.register(
            name: "Throwaway", phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences)

        let summary = try await harness.core.takeSnapshot(
            .id(instance.id), name: "Clean", notes: "", consent: .all, asEphemeralBaseline: true)

        #expect(instance.hostState.ephemeralBaselineSnapshotID == summary.id)
        #expect(virtualization.revertCallCount == 0)
    }
}
