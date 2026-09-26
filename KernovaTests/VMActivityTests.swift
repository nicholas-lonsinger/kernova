import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The operation machinery of ``VMActivity``: the admission commit, the one
/// ending commit, the session actions that take no admission, and the session
/// events that rest a settled VM or only mark an operation's session ended.
///
/// Every operation here is a real one committed by the activity — nothing is
/// placed over a running body — so what each test observes is what the
/// structure allows, not what a placed phase pretends.
@Suite("VMActivity Tests", .serialized, .admissionGated)
@MainActor
struct VMActivityTests {
    private struct Probe: Error, Equatable {}

    /// What the hooks and closures under test saw, in place of captured
    /// mutable locals.
    @MainActor
    private final class Recorder {
        var poweredOff = 0
        var sent = 0
        var terminations = 0
        var phase: VMLifecyclePhase?
        var operation: VMOperation?
        var sessionID: UUID?
        var sessionEnd: VMSessionEnd?
        var outcome: VMOutcome?
        var resolvedAtWhenEnded: Bool?
        var hookSawResolved: Bool?
        var hookProbe: Task<Void, Never>?
        var whenEndedResult: Result<Void, any Error>?
        var waitCancelled: Bool?
    }

    private func makeInstance(
        _ phase: VMLifecyclePhase, guestOS: VMGuestOS = .linux,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> (VMInstance, Recorder) {
        let instance = VMInstanceFixture.make(guestOS: guestOS, phase: phase, mutate: mutate)
        let recorder = Recorder()
        instance.activity.onPoweredOff = { recorder.poweredOff += 1 }
        return (instance, recorder)
    }

    /// A VM wired into a library whose build passes USB accessories through,
    /// holding one snapshot — so every live operation kind is admitted from a
    /// settled live phase. The caller keeps the library alive.
    private func makeWiredInstance(
        _ phase: VMLifecyclePhase
    ) -> (VMInstance, Recorder, VMLibrary) {
        let (instance, recorder) = makeInstance(phase)
        instance.seedSnapshotManifest(
            VMSnapshotManifest(snapshots: [VMSnapshot(name: "Baseline", macAddress: nil)]))
        let library = makeWiredLibrary(
            holding: [instance],
            lifecycle: makeTestLifecycle(usbAccessoryService: MockUSBAccessoryService()))
        // Wiring installs the library's own power-off hook; the recorder's
        // stands in for it here.
        instance.activity.onPoweredOff = { recorder.poweredOff += 1 }
        return (instance, recorder, library)
    }

    /// Launches `kind` with a body that parks on `gate` and then rests where
    /// it started.
    @discardableResult
    private func launchGated(
        _ kind: VMOperationKind, on instance: VMInstance, gate: GatedStep
    ) throws -> VMOutcome {
        if case .bringUp(let bringUp) = kind {
            return try instance.activity.launchBringUp(bringUp) { _ in
                try await gate.pass()
                return .rest(.asStarted, ())
            }
        }
        return try instance.activity.launch(kind) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
    }

    // MARK: - perform

    @Test("perform commits the operation from the phase it was admitted from and rests where the body says")
    func performCommitsAndRestsWhereTheBodySays() async throws {
        let session = UUID()
        let (instance, recorder) = makeInstance(.running(sessionID: session))

        try await instance.activity.perform(.pausing) { context in
            recorder.operation = instance.phase.operation
            recorder.sessionID = context.sessionID
            return .rest(.live(.paused), ())
        }

        let operation = try #require(recorder.operation)
        #expect(operation.kind == .pausing)
        #expect(operation.startedFrom == .running(sessionID: session))
        #expect(operation.session == VMOperationSession(id: session, guest: .running))
        #expect(operation.sessionEnd == nil)
        #expect(recorder.sessionID == session)
        #expect(instance.phase == .livePaused(sessionID: session))
    }

    @Test("A body that throws rests the VM where its kind's failure rest says, and rethrows")
    func throwingBodyRestsWhereTheKindSays() async throws {
        let session = UUID()
        let message = Probe().localizedDescription
        // Written out rather than read from `restAfterFailure`, so the commit
        // is checked against the rule and not against itself.
        let cases: [(VMOperationKind, VMLifecyclePhase, VMLifecyclePhase)] = [
            (.pausing, .running(sessionID: session), .running(sessionID: session)),
            // A failed hot resume leaves the guest where it was, still in memory.
            (.resuming, .livePaused(sessionID: session), .livePaused(sessionID: session)),
            (.saving, .running(sessionID: session), .failed(message: message)),
            (.deletingSnapshot, .stopped, .stopped),
            (.capturingSnapshot(.stopped), .stopped, .stopped),
            (
                .bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)),
                .running(sessionID: session), .stopped
            ),
        ]
        for (kind, startedFrom, rest) in cases {
            let (instance, _) = makeInstance(startedFrom)
            instance.seedSnapshotManifest(
                VMSnapshotManifest(snapshots: [VMSnapshot(name: "Baseline", macAddress: nil)]))
            await #expect(throws: Probe.self, "\(kind)") {
                if case .bringUp(let bringUp) = kind {
                    try await instance.activity.bringUp(bringUp) {
                        (_: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
                        throw Probe()
                    }
                } else {
                    try await instance.activity.perform(kind) {
                        (_: borrowing VMOperationContext) -> VMOperationEnding<Void> in
                        throw Probe()
                    }
                }
            }
            #expect(instance.phase == rest, "\(kind)")
        }

        // A bring-up's permanent failure is the failed phase carrying its
        // message; nothing is live after it.
        let (booting, _) = makeInstance(.stopped)
        await #expect(throws: Probe.self) {
            try await booting.activity.bringUp(.starting(recovery: false)) {
                (_: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
                throw Probe()
            }
        }
        #expect(booting.phase == .failed(message: message))
        #expect(!booting.hasLiveVirtualMachine)
    }

    @Test("A live rest over a session that ended mid-body rests where the end puts the VM")
    func liveRestOverAnEndedSessionRestsWhereTheEndSays() async throws {
        let session = UUID()
        let (instance, recorder) = makeInstance(.running(sessionID: session))

        try await instance.activity.perform(.pausing) { context in
            instance.activity.deliverSessionEvent(.didStopWithError(Probe()), from: session)
            recorder.sessionEnd = context.sessionEnd
            return .rest(.live(.paused), ())
        }

        #expect(recorder.sessionEnd == .stoppedWithError(message: Probe().localizedDescription))
        #expect(instance.phase == .failed(message: Probe().localizedDescription))
        // An error is not a power-off.
        #expect(recorder.poweredOff == 0)

        let (poweringOff, powerOffs) = makeInstance(.running(sessionID: session))
        try await poweringOff.activity.perform(.pausing) { _ in
            poweringOff.activity.deliverSessionEvent(.guestDidStop, from: session)
            // Held until the body ends: the hook fires at the ending commit.
            powerOffs.phase = poweringOff.phase
            #expect(powerOffs.poweredOff == 0)
            return .rest(.live(.paused), ())
        }
        #expect(powerOffs.phase?.operation?.kind == .pausing)
        #expect(poweringOff.phase == .stopped)
        #expect(powerOffs.poweredOff == 1)
    }

    @Test("performNow commits and ends in one step, and refuses what the phase does not admit")
    func performNowCommitsAndEndsInOneStep() throws {
        let (instance, recorder) = makeInstance(.suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        defer { VMInstanceFixture.removeBundle(of: instance) }

        // A body that throws rests where the kind says: back on the slot.
        #expect(throws: Probe.self) {
            try instance.activity.performNow(.discardingSavedState) {
                (_: borrowing VMOperationContext) -> VMOperationEnding<Void> in
                throw Probe()
            }
        }
        #expect(instance.phase == .suspended)

        try instance.activity.performNow(.discardingSavedState) { context in
            recorder.operation = instance.phase.operation
            context.bundle.removeSaveFile()
            return .rest(.atRest(.stopped), ())
        }
        #expect(recorder.operation?.kind == .discardingSavedState)
        #expect(recorder.operation?.startedFrom == .suspended)
        #expect(instance.phase == .stopped)

        // Nothing left to discard.
        #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try instance.activity.performNow(.discardingSavedState) { _ in .rest(.atRest(.stopped), ()) }
        }
    }

    // MARK: - launch

    @Test("launch returns with the operation committed, and its end hook sees the rest before the outcome resolves")
    func launchCommitsBeforeReturningAndEndsBeforeResolving() async throws {
        let (instance, recorder) = makeInstance(.stopped)
        let gate = GatedStep()

        let outcome = try instance.activity.launch(
            .deletingSnapshot,
            whenEnded: { result in
                recorder.phase = instance.phase
                recorder.whenEndedResult = result
                guard let outcome = recorder.outcome else { return }
                // Runs synchronously up to its first suspension: an outcome
                // already resolved answers without one.
                recorder.resolvedAtWhenEnded = false
                recorder.hookProbe = Task.immediate { @MainActor in
                    try? await outcome.value()
                    recorder.resolvedAtWhenEnded = true
                }
                recorder.hookSawResolved = recorder.resolvedAtWhenEnded
                recorder.operation = instance.phase.operation
            }
        ) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        recorder.outcome = outcome

        // No turn has passed: the operation already holds the VM.
        #expect(instance.phase.operation?.kind == .deletingSnapshot)
        #expect(instance.phase.operation?.outcome === outcome)
        #expect(instance.phase.operation?.startedFrom == .stopped)
        #expect(throws: VMAdmissionRefusal(refusal: .busy(.deletingSnapshot))) {
            try instance.activity.launch(.deletingSnapshot) { _ in .rest(.asStarted, ()) }
        }

        try await gate.waitUntilEntered()
        gate.release()
        try await outcome.value()

        #expect(recorder.phase == .stopped)
        #expect(recorder.operation == nil)
        #expect(recorder.hookSawResolved == false)
        await recorder.hookProbe?.value
        #expect(recorder.resolvedAtWhenEnded == true)
        #expect((try? recorder.whenEndedResult?.get()) != nil)
    }

    @Test("A launched body that throws reports the failure to its end hook and its outcome")
    func launchedFailureReachesTheHookAndTheOutcome() async throws {
        let session = UUID()
        let (instance, recorder) = makeInstance(.running(sessionID: session))

        let outcome = try instance.activity.launch(
            .deletingSnapshot,
            whenEnded: { result in
                recorder.phase = instance.phase
                recorder.whenEndedResult = result
            }
        ) { (_: borrowing VMOperationContext) -> VMOperationEnding<Void> in
            throw Probe()
        }
        await #expect(throws: Probe.self) { try await outcome.value() }

        #expect(recorder.phase == .running(sessionID: session))
        #expect(throws: Probe.self) { try recorder.whenEndedResult?.get() }
    }

    // MARK: - Joining

    @Test("A request that joins an operation awaits that operation's own outcome, success or failure")
    func joinAwaitsTheSameOutcome() async throws {
        for failure in [nil, Probe()] as [Probe?] {
            let (instance, _) = makeInstance(.stopped)
            let gate = GatedStep()
            let outcome = try instance.activity.launchBringUp(.starting(recovery: false)) { context in
                try await gate.pass()
                context.bindSessionForTesting(UUID())
                return .rest(.live(.running), ())
            }

            guard case .join(let joined) = instance.activity.decide(.start(recovery: false), posture: .commit)
            else {
                Issue.record("A Start during a Start did not join it")
                continue
            }
            #expect(joined === outcome)
            let joiner = Task { @MainActor in try await joined.value() }

            try await gate.waitUntilEntered()
            gate.release(throwing: failure)

            let direct = await Task { @MainActor in try await outcome.value() }.result
            let viaJoin = await joiner.result
            switch (direct, viaJoin) {
            case (.success, .success):
                #expect(failure == nil)
                #expect(instance.status == .running)
            case (.failure(let directError), .failure(let joinedError)):
                #expect(directError as? Probe == failure)
                #expect(joinedError as? Probe == failure)
            default:
                Issue.record("The joiner and the direct caller were told different things")
            }
        }
    }

    // MARK: - cancel

    @Test("Cancelling a guest setup cancels the task its operation runs in, and nothing else")
    func cancelCancelsTheSetupTask() async throws {
        let (instance, _) = makeInstance(.initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        let cancelled = AsyncGate()
        let recorder = Recorder()

        // Nothing to cancel at rest.
        #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try instance.activity.cancel(.guestSetup)
        }

        let outcome = try instance.launchParkedSetup {
            Task { @MainActor in
                recorder.sent += 1
                cancelled.notify()
            }
        }
        #expect(outcome.task?.isCancelled == false)
        try instance.activity.cancel(.guestSetup)
        #expect(outcome.task?.isCancelled == true)
        try await cancelled.wait { recorder.sent == 1 }

        await #expect(throws: CancellationError.self) { try await outcome.value() }
        #expect(instance.phase == .initialBoot)
    }

    @Test("A guest-setup cancel during another operation is refused and leaves it running")
    func cancelRefusedDuringAnotherOperation() async throws {
        let (instance, _) = makeInstance(.stopped)
        let gate = GatedStep()
        let outcome = try launchGated(.deletingSnapshot, on: instance, gate: gate)

        #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try instance.activity.cancel(.guestSetup)
        }
        #expect(outcome.task?.isCancelled == false)

        gate.release()
        try await outcome.value()
        #expect(instance.phase == .stopped)
    }

    // MARK: - remove

    @Test("remove is refused during an operation and moves a VM at rest to removed, which refuses everything")
    func removeRefusedWhileHeldAndFinalAtRest() async throws {
        let (live, _) = makeInstance(.running(sessionID: UUID()))
        #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) { try live.activity.remove() }

        let (instance, _) = makeInstance(.stopped)
        let gate = GatedStep()
        let outcome = try launchGated(.deletingSnapshot, on: instance, gate: gate)
        #expect(throws: VMAdmissionRefusal(refusal: .busy(.deletingSnapshot))) {
            try instance.activity.remove()
        }
        #expect(instance.phase.operation?.kind == .deletingSnapshot)
        gate.release()
        try await outcome.value()

        try instance.activity.remove()
        #expect(instance.phase == .removed)

        for capability in VMCapability.allCases {
            guard let request = capability.request(on: instance) else { continue }
            #expect(instance.activity.decide(request, posture: .commit) == .refuse(.removed), "\(capability)")
            #expect(instance.activity.decide(request, posture: .offer) == .refuse(.removed), "\(capability)")
        }
        let removed = VMAdmissionRefusal(refusal: .removed)
        await #expect(throws: removed) {
            try await instance.activity.perform(.deletingSnapshot) { _ in .rest(.asStarted, ()) }
        }
        #expect(throws: removed) {
            try instance.activity.launch(.deletingSnapshot) { _ in .rest(.asStarted, ()) }
        }
        await #expect(throws: removed) { try await instance.activity.requestStop {} }
        await #expect(throws: removed) { try await instance.activity.forceStop {} }
        #expect(throws: removed) { try instance.activity.cancel(.guestSetup) }
        #expect(throws: removed) { try instance.activity.remove() }
        #expect(instance.phase == .removed)
    }

    // MARK: - Session events

    @Test("A settled session end rests the VM, and only a power-off fires the power-off hook")
    func settledSessionEndRestsTheVM() throws {
        let session = UUID()
        let message = Probe().localizedDescription
        let cases: [(VMLifecyclePhase, VMSessionEvent, VMLifecyclePhase, Int)] = [
            (.running(sessionID: session), .guestDidStop, .stopped, 1),
            (.livePaused(sessionID: session), .guestDidStop, .stopped, 1),
            (.running(sessionID: session), .didStopWithError(Probe()), .failed(message: message), 0),
            (.livePaused(sessionID: session), .didStopWithError(Probe()), .failed(message: message), 0),
        ]
        for (phase, event, rest, powerOffs) in cases {
            let (instance, recorder) = makeInstance(phase)
            instance.beginSessionContextForTesting()

            // One raised by a session the VM no longer holds is dropped.
            instance.activity.deliverSessionEvent(event, from: UUID())
            #expect(instance.phase == phase)

            instance.activity.deliverSessionEvent(event, from: session)
            #expect(instance.phase == rest, "\(phase) \(event)")
            #expect(instance.activity.sessionContext == nil)
            #expect(recorder.poweredOff == powerOffs, "\(phase) \(event)")
        }

        // A slot that survived the session is what the VM comes back on.
        let (suspending, recorder) = makeInstance(.running(sessionID: session))
        try VMInstanceFixture.writeSaveFile(for: suspending)
        defer { VMInstanceFixture.removeBundle(of: suspending) }
        suspending.activity.deliverSessionEvent(.guestDidStop, from: session)
        #expect(suspending.phase == .suspended)
        #expect(recorder.poweredOff == 1)
    }

    @Test("A session end during an operation keeps the operation and marks its session ended")
    func sessionEndDuringAnOperationKeepsIt() async throws {
        let message = Probe().localizedDescription
        let cases: [(VMSessionEvent, VMSessionEnd)] = [
            (.guestDidStop, .poweredOff),
            (.didStopWithError(Probe()), .stoppedWithError(message: message)),
        ]
        for (event, end) in cases {
            let session = UUID()
            let (instance, recorder) = makeInstance(.running(sessionID: session))
            instance.beginSessionContextForTesting()
            let gate = GatedStep()
            let outcome = try launchGated(.deletingSnapshot, on: instance, gate: gate)
            try await gate.waitUntilEntered()

            instance.activity.deliverSessionEvent(event, from: session)

            let operation = try #require(instance.phase.operation)
            #expect(operation.kind == .deletingSnapshot)
            #expect(operation.outcome === outcome)
            #expect(operation.session == nil)
            #expect(operation.sessionEnd == end)
            #expect(operation.startedFrom == .running(sessionID: session))
            #expect(!instance.hasLiveVirtualMachine)
            #expect(instance.activity.sessionContext == nil)
            #expect(recorder.poweredOff == 0)

            gate.release()
            try await outcome.value()
            let rest: VMLifecyclePhase = end == .poweredOff ? .stopped : .failed(message: message)
            #expect(instance.phase == rest)
            #expect(recorder.poweredOff == (end == .poweredOff ? 1 : 0))
        }
    }

    @Test("A body waiting for its session to end is answered how it ended")
    func sessionEndedAnswersTheEnd() async throws {
        let session = UUID()
        let (instance, recorder) = makeInstance(.running(sessionID: session))
        instance.beginSessionContextForTesting()
        let entered = GatedStep()
        entered.release()

        let outcome = try instance.activity.launch(.deletingSnapshot) { context in
            // Runs on to its wait before the test resumes.
            try await entered.pass()
            recorder.sessionEnd = try await context.sessionEnded()
            return .rest(.asStarted, ())
        }
        try await entered.waitUntilEntered()
        #expect(recorder.sessionEnd == nil)

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        try await outcome.value()
        #expect(recorder.sessionEnd == .poweredOff)
        #expect(instance.phase == .stopped)
    }

    @Test("Cancelling a guest setup wakes a body waiting for its session to end")
    func sessionEndedThrowsOnCancel() async throws {
        let (instance, recorder) = makeInstance(.initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        let entered = GatedStep()
        entered.release()

        let outcome = try instance.activity.launchBringUp(.settingUp(.macOSInstall)) { context in
            context.bindSessionForTesting(UUID())
            try await entered.pass()
            do {
                recorder.sessionEnd = try await context.operation.sessionEnded()
            } catch {
                recorder.waitCancelled = error is CancellationError
                throw error
            }
            return .rest(.live(.running), ())
        }
        try await entered.waitUntilEntered()

        try instance.activity.cancel(.guestSetup)
        await #expect(throws: CancellationError.self) { try await outcome.value() }
        #expect(recorder.waitCancelled == true)
        #expect(recorder.sessionEnd == nil)
        #expect(instance.phase == .initialBoot)
        #expect(!instance.hasLiveVirtualMachine)
    }

    // MARK: - Force Stop

    @Test("Force Stop of a settled live VM is its own short operation ending in a power-off")
    func forceStopOfASettledVMIsAnOperation() async throws {
        let (instance, recorder) = makeInstance(.running(sessionID: UUID()))

        try await instance.activity.forceStop {
            recorder.terminations += 1
            recorder.operation = instance.phase.operation
        }

        #expect(recorder.terminations == 1)
        #expect(recorder.operation?.kind == .forceStopping)
        #expect(instance.phase == .stopped)
        #expect(recorder.poweredOff == 1)

        // Nothing live to stop.
        await #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try await instance.activity.forceStop { recorder.terminations += 1 }
        }
        #expect(recorder.terminations == 1)
    }

    @Test("A second Force Stop joins the first rather than terminating again")
    func secondForceStopJoinsTheFirst() async throws {
        let (instance, recorder) = makeInstance(.running(sessionID: UUID()))
        let gate = GatedStep()

        let first = Task { @MainActor in
            try await instance.activity.forceStop {
                recorder.terminations += 1
                try await gate.pass()
            }
        }
        try await gate.waitUntilEntered()
        let held = try #require(instance.phase.operation)
        #expect(held.kind == .forceStopping)
        #expect(instance.activity.decide(.sessionAction(.forceStop), posture: .commit) == .join(held.outcome))

        // Entered synchronously, so it is parked on the outcome before the
        // release below can end the first.
        let second = Task.immediate { @MainActor in
            try await instance.activity.forceStop { recorder.terminations += 1 }
        }
        gate.release()
        try await first.value
        try await second.value

        #expect(recorder.terminations == 1)
        #expect(instance.phase == .stopped)
        #expect(recorder.poweredOff == 1)
    }

    /// One operation of every kind that holds a live session, admitted from
    /// the settled live phase it starts from.
    private func liveOperations(session: UUID) -> [(VMOperationKind, VMLifecyclePhase)] {
        let running = VMLifecyclePhase.running(sessionID: session)
        return [
            (.pausing, running),
            (.resuming, .livePaused(sessionID: session)),
            (.saving, running),
            (.capturingSnapshot(.live), running),
            (.deletingSnapshot, running),
            (.attachingUSB(registryID: 1), running),
            (.detachingUSB(deviceID: UUID()), running),
            (.reconcilingMedia, running),
            (.bringUp(.reverting(snapshotID: UUID(), resumesAfter: true)), running),
        ]
    }

    @Test("Every kind that tolerates a stop keeps holding the VM through a stop request and a Force Stop")
    func toleratingKindsKeepHoldingThroughBothStops() async throws {
        let session = UUID()
        let tolerating = liveOperations(session: session).filter {
            $0.0.declaration.toleratedSessionActions.contains(.forceStop)
        }
        #expect(!tolerating.isEmpty)
        for (kind, startedFrom) in tolerating {
            let (instance, recorder, library) = makeWiredInstance(startedFrom)
            let gate = GatedStep()
            let outcome = try launchGated(kind, on: instance, gate: gate)
            try await gate.waitUntilEntered()
            let held = instance.phase

            try await instance.activity.requestStop { recorder.sent += 1 }
            #expect(recorder.sent == 1, "\(kind)")
            #expect(instance.phase == held, "\(kind)")

            try await instance.activity.forceStop { recorder.terminations += 1 }
            #expect(recorder.terminations == 1, "\(kind)")
            let operation = try #require(instance.phase.operation, "\(kind)")
            #expect(operation.kind == kind)
            #expect(operation.outcome === outcome, "\(kind)")
            #expect(operation.session == nil, "\(kind)")
            #expect(operation.sessionEnd == .poweredOff, "\(kind)")
            #expect(recorder.poweredOff == 0, "\(kind)")

            gate.release()
            try await outcome.value()
            #expect(instance.phase == .stopped, "\(kind)")
            #expect(recorder.poweredOff == 1, "\(kind)")
            withExtendedLifetime(library) {}
        }
    }

    @Test("An operation that ends before its Force Stop lands hands the VM to that Force Stop")
    func operationEndingOnAStoppingSessionHandsOver() async throws {
        let session = UUID()
        let tolerating = liveOperations(session: session).filter {
            $0.0.declaration.toleratedSessionActions.contains(.forceStop)
        }
        #expect(!tolerating.isEmpty)
        for (kind, startedFrom) in tolerating {
            for slot in [false, true] {
                let (instance, recorder, library) = makeWiredInstance(startedFrom)
                defer { VMInstanceFixture.removeBundle(of: instance) }
                let body = GatedStep()
                let terminate = GatedStep()
                let outcome = try launchGated(kind, on: instance, gate: body)
                try await body.waitUntilEntered()

                let first = Task { @MainActor in
                    try await instance.activity.forceStop {
                        recorder.terminations += 1
                        try await terminate.pass()
                    }
                }
                try await terminate.waitUntilEntered()
                #expect(instance.phase.operation?.kind == kind, "\(kind)")
                #expect(instance.phase.operation?.session?.stopping != nil, "\(kind)")
                // Entered synchronously, so it is parked on the stop before
                // anything below can land it.
                let second = Task.immediate { @MainActor in
                    try await instance.activity.forceStop { recorder.terminations += 1 }
                }

                if slot { try VMInstanceFixture.writeSaveFile(for: instance) }
                body.release()
                try await outcome.value()

                let handed = try #require(instance.phase.operation, "\(kind)")
                #expect(handed.kind == .forceStopping, "\(kind)")
                #expect(handed.session?.id == session, "\(kind)")
                #expect(!instance.phase.isSettledLive, "\(kind)")
                for request: VMAdmission.Request in [.operation(.saving), .resume] {
                    guard case .refuse = instance.activity.decide(request, posture: .commit) else {
                        Issue.record("\(request) admitted on a stopping session after \(kind)")
                        continue
                    }
                }
                #expect(recorder.poweredOff == 0, "\(kind)")

                terminate.release()
                try await first.value
                try await second.value
                #expect(recorder.terminations == 1, "\(kind)")
                #expect(instance.phase == (slot ? .suspended : .stopped), "\(kind)")
                #expect(recorder.poweredOff == 1, "\(kind)")
                withExtendedLifetime(library) {}
            }
        }
    }

    @Test("A Force Stop whose termination fails ends the stop for every caller and leaves the VM live")
    func failedTerminationEndsTheStop() async throws {
        let session = UUID()
        // Once the operation has handed the VM over, and while it still holds it.
        for handsOver in [true, false] {
            let (instance, recorder, library) = makeWiredInstance(.running(sessionID: session))
            let body = GatedStep()
            let terminate = GatedStep()
            let outcome = try launchGated(.deletingSnapshot, on: instance, gate: body)
            try await body.waitUntilEntered()

            let first = Task { @MainActor in
                try await instance.activity.forceStop { try await terminate.pass() }
            }
            try await terminate.waitUntilEntered()
            let second = Task.immediate { @MainActor in
                try await instance.activity.forceStop { recorder.terminations += 1 }
            }
            if handsOver {
                body.release()
                try await outcome.value()
                #expect(instance.phase.operation?.kind == .forceStopping)
            }

            terminate.release(throwing: Probe())
            await #expect(throws: Probe.self) { try await first.value }
            await #expect(throws: Probe.self) { try await second.value }
            #expect(recorder.terminations == 0)
            if !handsOver {
                #expect(instance.phase.operation?.kind == .deletingSnapshot)
                #expect(instance.phase.operation?.session?.stopping == nil)
                body.release()
                try await outcome.value()
            }
            #expect(instance.phase == .running(sessionID: session), "\(handsOver)")
            #expect(recorder.poweredOff == 0)
            withExtendedLifetime(library) {}
        }
    }

    @Test("A kind that tolerates no stop refuses both stops as busy and never reaches the VM")
    func nonToleratingKindsRefuseBothStops() async throws {
        let session = UUID()
        let refusing = liveOperations(session: session).filter {
            $0.0.declaration.toleratedSessionActions.isEmpty
        }
        #expect(!refusing.isEmpty)
        for (kind, startedFrom) in refusing {
            let (instance, recorder, library) = makeWiredInstance(startedFrom)
            let gate = GatedStep()
            let outcome = try launchGated(kind, on: instance, gate: gate)
            try await gate.waitUntilEntered()
            let held = instance.phase

            let busy = VMAdmissionRefusal(refusal: .busy(kind))
            await #expect(throws: busy, "\(kind)") {
                try await instance.activity.requestStop { recorder.sent += 1 }
            }
            await #expect(throws: busy, "\(kind)") {
                try await instance.activity.forceStop { recorder.terminations += 1 }
            }
            #expect(recorder.sent == 0, "\(kind)")
            #expect(recorder.terminations == 0, "\(kind)")
            #expect(instance.phase == held, "\(kind)")

            gate.release()
            try await outcome.value()
            #expect(instance.phase == startedFrom, "\(kind)")
            withExtendedLifetime(library) {}
        }
    }

    // MARK: - Graceful stop

    @Test("A stop request takes no admission and moves no phase")
    func requestStopMovesNoPhase() async throws {
        let session = UUID()
        let (instance, recorder) = makeInstance(.running(sessionID: session))

        try await instance.activity.requestStop {
            recorder.sent += 1
            recorder.phase = instance.phase
        }
        #expect(recorder.sent == 1)
        #expect(recorder.phase == .running(sessionID: session))
        #expect(instance.phase == .running(sessionID: session))

        // Nothing to ask at rest.
        let (resting, restingRecorder) = makeInstance(.stopped)
        await #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try await resting.activity.requestStop { restingRecorder.sent += 1 }
        }
        #expect(restingRecorder.sent == 0)
    }

    // MARK: - Binding a session

    @Test("A bring-up's bound session is the operation's, and the rest it commits")
    func bindSessionBindsToTheBringUp() async throws {
        let (instance, recorder) = makeInstance(.stopped)
        let session = UUID()

        try await instance.activity.bringUp(.starting(recovery: false)) { context in
            recorder.sessionID = context.operation.sessionID
            #expect(instance.liveSessionID == nil)
            context.bindSessionForTesting(session)
            #expect(context.operation.sessionID == session)
            #expect(instance.phase.operation?.session == VMOperationSession(id: session, guest: .running))
            #expect(instance.liveSessionID == session)
            return .rest(.live(.running), ())
        }

        #expect(recorder.sessionID == nil)
        #expect(instance.phase == .running(sessionID: session))
    }

    @Test("A bring-up that fails before binding a session releases the context it opened")
    func failedBringUpReleasesItsOpenContext() async throws {
        let (instance, _) = makeInstance(.stopped)

        await #expect(throws: Probe.self) {
            try await instance.activity.bringUp(.starting(recovery: false)) {
                (_: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
                instance.beginSessionContextForTesting()
                throw Probe()
            }
        }

        #expect(instance.activity.sessionContext == nil)
        #expect(!instance.hasLiveVirtualMachine)
    }
}
