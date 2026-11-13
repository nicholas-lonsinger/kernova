import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The unsettled-session marker (``VMHostState/hasUnsettledSession``): what
/// sets it, what settles it, and the one rule a session found ended unsettled
/// answers to — an Ephemeral VM's baseline revert, which every request
/// carrying the guest's files forward waits out — and how a session
/// Virtualization stopped with an error is told, however it settles.
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
        phase: VMLifecyclePhase = .stopped, agentConnector: (any HostConnectionMaking)? = nil,
        mutate: (inout VMConfiguration) -> Void = { _ in }
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
            library: harness.library, preferences: preferences, hostState: hostState,
            agentConnector: agentConnector, mutate: mutate)
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

    // MARK: - Settling

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

    // MARK: - A session stopped with an error

    /// An error as Virtualization stops a session with one.
    private static let stopError = NSError(
        domain: "VZErrorDomain", code: 1,
        userInfo: [
            NSLocalizedDescriptionKey:
                "Internal Virtualization error. The virtual machine stopped unexpectedly."
        ])

    /// What records each failure alert `harness`'s library raises.
    private func recordingAlerts(of harness: WiredCommandCore) -> MockLibraryFailureSink {
        let alerts = MockLibraryFailureSink()
        harness.library.onFailure = { [alerts] title, message, subject in
            alerts.record(title: title, message: message, subject: subject)
        }
        return alerts
    }

    /// Where a VM's session ending with an error leaves it.
    enum CrashedVM: CaseIterable, Sendable {
        /// Not in Ephemeral Mode: failed, with the error's message.
        case notEphemeral
        /// Back at a cold baseline: stopped.
        case coldBaseline
        /// Back at a warm baseline: suspended.
        case warmBaseline
    }

    @Test(
        "A session Virtualization stops with an error raises one alert and one stream failure, wherever the VM rests",
        arguments: CrashedVM.allCases)
    func sessionStoppedWithErrorIsToldOnce(vm: CrashedVM) async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let alerts = recordingAlerts(of: harness)
        let session = UUID()
        let (instance, baseline, _) = try makeVM(
            in: harness, baseline: vm == .warmBaseline ? .warm : .cold, ephemeral: vm != .notEphemeral,
            phase: .running(sessionID: session))
        let events = harness.core.events()

        instance.activity.deliverSessionEvent(.didStopWithError(Self.stopError), from: session)
        await harness.library.waitForRevertsToSettle()

        let message = "Internal Virtualization error. The virtual machine stopped unexpectedly."
        switch vm {
        case .notEphemeral:
            #expect(instance.phase == .failed(message: message))
            #expect(virtualization.revertedSnapshots.isEmpty)
        case .coldBaseline:
            #expect(instance.phase == .stopped)
            #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        case .warmBaseline:
            #expect(instance.phase == .suspended)
            #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        }
        #expect(alerts.errors == [message])
        #expect(alerts.errorTitles == ["\u{201C}Throwaway\u{201D} Stopped Because of an Error"])
        if case .vm(let subject)? = alerts.errorSubject {
            #expect(subject === instance)
        } else {
            Issue.record("The alert was about \(String(describing: alerts.errorSubject))")
        }

        let reported = try await harness.eventsReadPastRename(of: instance, on: events)
        let failures = reported.compactMap { event -> String? in
            guard case .failure(_, _, let message) = event else { return nil }
            return message
        }
        #expect(failures == [message])
        // An Ephemeral VM is told its failure without ever reading Error.
        let statuses = reported.compactMap { event -> String? in
            guard case .statusChanged(_, _, _, let to) = event else { return nil }
            return to
        }
        #expect(statuses.contains(VMStatus.error.rawValue) == (vm == .notEphemeral))
    }

    @Test("A session stopped with an error while a start holds the VM is told as it ends, once")
    func sessionStoppedWithErrorUnderAnOperationIsToldOnce() async throws {
        let virtualization = MockVirtualizationService()
        let gate = GatedStep()
        virtualization.startGate = gate
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let alerts = recordingAlerts(of: harness)
        let (instance, _, _) = try makeVM(in: harness, ephemeral: false)
        let events = harness.core.events()

        let start = Task { @MainActor in
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        try await gate.waitUntilEntered()
        let session = try #require(instance.liveSessionID)
        instance.activity.deliverSessionEvent(.didStopWithError(Self.stopError), from: session)

        let message = "Internal Virtualization error. The virtual machine stopped unexpectedly."
        #expect(!instance.phase.isSettled)
        #expect(alerts.errors == [message])
        gate.release()
        _ = try? await start.value

        #expect(instance.phase == .failed(message: message))
        #expect(alerts.errors == [message])
        #expect(try await harness.failureMessages(of: instance, on: events) == [message])
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
            try await harness.core.restart(.id(instance.id), disposition: .graceful, timeout: nil, consent: .none)
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

    @Test("A Force Restart keeps an Ephemeral VM's session and boots it, as its prompt says, with no revert")
    func forceRestartKeepsTheSession() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization, preferences: preferences)
        let (instance, baseline, _) = try makeVM(in: harness, phase: .running(sessionID: UUID()))
        let message = VMCommandCore.forceRestartPrompt(instance).message
        #expect(
            message.hasSuffix(
                " It is ephemeral, and a restart keeps its session rather than returning it to "
                    + "\u{201C}\(baseline.name)\u{201D}."))
        #expect(VMCommandCore.restartAnywayPrompt(instance).message.hasSuffix(String(message.suffix(60))))

        try await harness.core.restart(
            .id(instance.id), disposition: .force, timeout: nil, consent: Consent([.forceRestart]))

        #expect(virtualization.forceStopCallCount == 1)
        #expect(virtualization.revertCallCount == 0)
        #expect(virtualization.lastStartRoute == .coldBoot)
        #expect(instance.status == .running)
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
        let revert = GatedStep()
        virtualization.revertGate = revert

        let restart = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), disposition: .graceful, timeout: nil, consent: .none)
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
        // The restart reports without waiting out the revert its stop owes, so
        // the VM it names is the one that revert holds.
        #expect(instance.isHeldByRevert)
        #expect(error == .restartCancelledByStop(vm: harness.core.summary(instance)))
        revert.release()
        // A waiting caller reads it as the restart that ran and did not complete.
        guard case .operationFailed(.restart, _, let message, _) = error.dto else {
            Issue.record("Expected the restart to cross as a failed restart, got \(error.dto)")
            return
        }
        #expect(message.contains("was stopped while it restarted"))
        await harness.library.waitForRevertsToSettle()

        #expect(virtualization.startCallCount == 0)
        #expect(virtualization.revertedSnapshots.map(\.id) == [baseline.id])
        #expect(!instance.hostState.hasUnsettledSession)
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

    // MARK: - Waiting

    @Test("A live Exact Copy arrives settled")
    func liveExactCopyArrivesSettled() async throws {
        let harness = WiredCommandCore(preferences: preferences)
        let (instance, _, _) = try makeVM(in: harness, phase: .running(sessionID: UUID()))
        #expect(instance.hostState.hasUnsettledSession)

        let summary = try await harness.core.clone(
            .id(instance.id), outcome: .exactCopy, waitForOutcome: true)

        let clone = try #require(harness.library.instances.first { $0.id == summary.id })
        #expect(!clone.hostState.hasUnsettledSession)
        #expect(instance.hostState.hasUnsettledSession)
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
                _ = try await harness.core.takeSnapshot(.id(instance.id), name: "After", notes: "")
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
}
