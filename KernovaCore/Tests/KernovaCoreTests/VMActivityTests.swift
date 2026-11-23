import Foundation
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The operation machinery of ``VMActivity``: the admission commit, the one
/// ending commit, the session actions that take no admission, and the session
/// events that rest a settled VM or only mark an operation's session ended.
///
/// Every operation here is a real one committed by the activity — nothing is
/// placed over a running body — so what each test observes is what the
/// structure allows, not what a placed phase pretends.
@Suite("VMActivity Tests", .serialized, .caseScoped)
@MainActor
struct VMActivityTests {
    private struct Probe: Error, Equatable {}

    /// What the hooks and closures under test saw, in place of captured
    /// mutable locals.
    @MainActor
    private final class Recorder {
        /// How many session ends were settled.
        var settled = 0
        var sent = 0
        var terminations = 0
        var phase: VMLifecyclePhase?
        var operation: VMOperation?
        var outcome: VMOutcome?
        var resolvedAtWhenEnded: Bool?
        var hookSawResolved: Bool?
        var hookProbe: Task<Void, Never>?
        var whenEndedResult: Result<Void, any Error>?
    }

    private func makeInstance(
        _ phase: VMLifecyclePhase, guestOS: VMGuestOS = .linux,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> (VMInstance, Recorder) {
        let instance = VMInstanceFixture.make(guestOS: guestOS, phase: phase, mutate: mutate)
        let recorder = Recorder()
        instance.activity.onUnsettledSession = {
            recorder.settled += 1
            return []
        }
        return (instance, recorder)
    }

    /// A VM wired into a library whose process passes USB accessories through,
    /// holding one snapshot — so every live operation kind is admitted from a
    /// settled live phase. The caller keeps the library alive.
    private func makeWiredInstance(
        _ phase: VMLifecyclePhase
    ) -> (VMInstance, Recorder, VMLibrary) {
        let library = makeWiredLibrary(
            lifecycle: makeTestLifecycle(usbAccessoryPassthrough: .available(MockUSBAccessoryService())))
        let instance = library.registerFixture(
            phase: phase,
            snapshots: VMSnapshotManifest(snapshots: [VMSnapshot(name: "Baseline", macAddress: nil)]))
        let recorder = Recorder()
        // Wiring installs the library's own settling hook; the recorder's
        // stands in for it here.
        instance.activity.onUnsettledSession = {
            recorder.settled += 1
            return []
        }
        return (instance, recorder, library)
    }

    /// Launches `kind` with a body that parks on `gate` and then rests where
    /// it started.
    @discardableResult
    private func launchGated(
        _ kind: VMOperationKind, on instance: VMInstance, gate: GatedStep
    ) throws -> VMOutcome {
        guard let nonBringUp = VMNonBringUpKind(kind) else {
            guard case .bringUp(let bringUp) = kind else { preconditionFailure("\(kind)") }
            return try instance.activity.launchAnyBringUp(bringUp) { _ in
                try await gate.pass()
                return .rest(.asStarted, ())
            }
        }
        return try instance.activity.launch(nonBringUp) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
    }

    // MARK: - perform

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
                    try await instance.activity.launchAnyBringUp(bringUp) {
                        (_: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
                        throw Probe()
                    }.resolved()
                } else {
                    try await instance.activity.perform(try #require(VMNonBringUpKind(kind))) {
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
            try await booting.activity.launchAnyBringUp(.guestStart(.starting(recovery: false))) {
                (_: borrowing VMBringUpContext) -> VMOperationEnding<Void> in
                throw Probe()
            }.resolved()
        }
        #expect(booting.phase == .failed(message: message))
        #expect(!booting.hasLiveVirtualMachine)
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
                guard let outcome = recorder.outcome else { return [] }
                // Runs synchronously up to its first suspension: an outcome
                // already resolved answers without one.
                recorder.resolvedAtWhenEnded = false
                recorder.hookProbe = Task.immediate { @MainActor in
                    try? await outcome.value()
                    recorder.resolvedAtWhenEnded = true
                }
                recorder.hookSawResolved = recorder.resolvedAtWhenEnded
                recorder.operation = instance.phase.operation
                return []
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
        try await outcome.resolved()

        #expect(recorder.phase == .stopped)
        #expect(recorder.operation == nil)
        #expect(recorder.hookSawResolved == false)
        try await recorder.hookProbe?.joined()
        #expect(recorder.resolvedAtWhenEnded == true)
        #expect((try? recorder.whenEndedResult?.get()) != nil)
    }

    // MARK: - Force Stop

    @Test(
        "A Force Stop whose stop never completes ends — for its caller and a joiner — when the session ends another way, leaving nothing pending",
        arguments: SessionEndUnderAStop.allCases)
    func forceStopEndsWithItsSession(_ end: SessionEndUnderAStop) async throws {
        let event: VMSessionEvent =
            switch end {
            case .stoppedWithError: .didStopWithError(Probe())
            case .guestStopped: .guestDidStop
            }
        let session = UUID()
        let (instance, recorder) = makeInstance(.running(sessionID: session))
        instance.beginSessionContextForTesting()

        // The send returns and no completion ever arrives.
        let first = try instance.activity.forceStop { recorder.terminations += 1 }
        let joined = try instance.activity.forceStop { recorder.terminations += 1 }
        let waiters = [first, joined].map { stop in
            Task { @MainActor in try await stop.resolved() }
        }
        #expect(instance.status == .forceStopping)

        instance.activity.deliverSessionEvent(event, from: session)
        for waiter in waiters { try await waiter.joined() }

        #expect(recorder.terminations == 1)
        #expect(instance.activity.pendingForceStop == nil)
        #expect(instance.phase == .stopped)
        #expect(instance.activity.sessionContext == nil)
        #expect(recorder.settled == 1)
        // A completion arriving after the end belongs to no session the VM
        // holds.
        instance.activity.deliverSessionEvent(.stopDidComplete, from: session)
        instance.activity.deliverSessionEvent(.stopDidFail(Probe()), from: session)
        #expect(recorder.settled == 1)
    }

    @Test(
        "An operation's stop of its own session ends on the session ending another way, with no completion",
        arguments: SessionEndUnderAStop.allCases)
    func operationStopEndsWithItsSession(_ end: SessionEndUnderAStop) async throws {
        let session = UUID()
        let (instance, _) = makeInstance(.running(sessionID: session))
        let recorder = StopRecordingSession(id: session)
        instance.beginSessionContextForTesting().session = recorder

        let outcome = try instance.activity.launch(.deletingSnapshot) { context in
            try await context.stopSession()
            return .rest(.afterSessionEnd, ())
        }
        try await recorder.stopped.wait { recorder.stops == 1 }
        #expect(instance.status == .running)

        let event: VMSessionEvent =
            switch end {
            case .stoppedWithError: .didStopWithError(Probe())
            case .guestStopped: .guestDidStop
            }
        instance.activity.deliverSessionEvent(event, from: session)
        try await outcome.resolved()
        #expect(instance.phase.operation == nil)
        #expect(!instance.hasLiveVirtualMachine)
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

            try await instance.activity.requestStop { _ in recorder.sent += 1 }
            #expect(recorder.sent == 1, "\(kind)")
            #expect(instance.phase == held, "\(kind)")

            let stop = try instance.activity.forceStop { recorder.terminations += 1 }
            #expect(recorder.terminations == 1, "\(kind)")
            let session = try #require(instance.liveSessionID, "\(kind)")
            instance.activity.deliverSessionEvent(.stopDidComplete, from: session)
            try await stop.resolved()
            let operation = try #require(instance.phase.operation, "\(kind)")
            #expect(operation.kind == kind)
            #expect(operation.outcome === outcome, "\(kind)")
            #expect(operation.session == nil, "\(kind)")
            #expect(operation.sessionEnd == .poweredOff, "\(kind)")
            #expect(recorder.settled == 0, "\(kind)")

            gate.release()
            try await outcome.resolved()
            #expect(instance.phase == .stopped, "\(kind)")
            #expect(recorder.settled == 1, "\(kind)")
            withExtendedLifetime(library) {}
        }
    }
}

/// A session that counts the stops sent to it and answers nothing else — the
/// VM process a stop is waiting on.
private final class StopRecordingSession: VMSessionOperating, @unchecked Sendable {
    let id: UUID
    let hasUSBController = false
    /// Fires as each stop arrives, after ``stops`` rises.
    let stopped = AsyncGate()
    private let lock = NSLock()
    private var stopCount = 0

    var stops: Int { lock.withLock { stopCount } }

    init(id: UUID) {
        self.id = id
    }

    func stop() {
        lock.withLock { stopCount += 1 }
        stopped.notify()
    }

    func requestStop() async throws {}
    func pause() async throws {}
    func attachMassStorage(url: URL, readOnly: Bool, uuid: UUID?) async throws -> UUID { UUID() }
    func makeAgentTransport() -> (any GuestStreamTransport)? { nil }
    func applyDirectoryShare(_ share: MacOSDirectoryShare, installed: @escaping @Sendable () -> Void) {}
    func pauseIfRunning() async throws {}
    func resumeIfPaused(_ execution: borrowing VMGuestExecution) async throws {}
    func saveMachineState(to url: URL, _ grant: VMLiveStateCapture.SaveGrant) async throws {}
    func restoreMachineState(from url: URL) async throws {}
    func resume(_ execution: borrowing VMGuestExecution) async throws {}
    func detachUSBDevice(uuid: UUID) async throws {}
}

/// The ways Virtualization can end a session a Force Stop is waiting on before
/// the stop's completion arrives, if it ever does.
enum SessionEndUnderAStop: CaseIterable, Sendable {
    /// `didStopWithError` — what killing the VM's process raises.
    case stoppedWithError
    /// `guestDidStop`.
    case guestStopped
}
