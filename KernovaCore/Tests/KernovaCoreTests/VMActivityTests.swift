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
        /// The messages ``VMActivity/onSessionStoppedWithError`` fired with.
        var stoppedWithError: [String] = []
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
        var guestStart: VMGuestStartKind?
        var captureMode: VMCaptureMode?
        var revertedTo: (snapshotID: UUID, resumesAfter: Bool)?
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

    @Test("Each typed entry point commits its kind and hands the body what it was admitted with")
    func typedEntryPointsCarryTheirKind() async throws {
        let (starting, startRecorder) = makeInstance(.stopped)
        try await starting.activity.launchStartGuest(.starting(recovery: false)) { context in
            startRecorder.operation = starting.phase.operation
            startRecorder.guestStart = context.kind
            return .rest(.asStarted, ())
        }.resolved()
        #expect(startRecorder.operation?.kind == .bringUp(.guestStart(.starting(recovery: false))))
        #expect(startRecorder.guestStart == .starting(recovery: false))

        let (capturing, captureRecorder) = makeInstance(.stopped)
        try await capturing.activity.launchedCapture(.stopped) { context in
            captureRecorder.operation = capturing.phase.operation
            captureRecorder.captureMode = context.mode
            return .rest(.asStarted, ())
        }
        #expect(captureRecorder.operation?.kind == .capturingSnapshot(.stopped))
        #expect(captureRecorder.captureMode == .stopped)

        let snapshot = VMSnapshot(name: "Baseline", macAddress: nil)
        let (reverting, revertRecorder) = makeInstance(.stopped)
        reverting.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        try await reverting.activity.launchRevert(to: snapshot, resumesAfter: false) { context in
            revertRecorder.operation = reverting.phase.operation
            revertRecorder.revertedTo = (context.snapshot.id, context.resumesAfter)
            return .rest(.asStarted, ())
        }.resolved()
        #expect(
            revertRecorder.operation?.kind
                == .bringUp(.reverting(snapshotID: snapshot.id, resumesAfter: false)))
        #expect(revertRecorder.revertedTo?.snapshotID == snapshot.id)
        #expect(revertRecorder.revertedTo?.resumesAfter == false)
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
        // An error ends the session as a power-off does.
        #expect(recorder.settled == 1)

        let (poweringOff, powerOffs) = makeInstance(.running(sessionID: session))
        try await poweringOff.activity.perform(.pausing) { _ in
            poweringOff.activity.deliverSessionEvent(.guestDidStop, from: session)
            // Held until the body ends: the session is settled at the ending
            // commit.
            powerOffs.phase = poweringOff.phase
            #expect(powerOffs.settled == 0)
            return .rest(.live(.paused), ())
        }
        #expect(powerOffs.phase?.operation?.kind == .pausing)
        #expect(poweringOff.phase == .stopped)
        #expect(powerOffs.settled == 1)
    }

    // MARK: - Edits

    @Test("A commit refuses every field its permit's classes may not write, and changes nothing")
    func aCommitRefusesFieldsOutsideItsPermit() throws {
        let (instance, _, library) = makeWiredInstance(.running(sessionID: UUID()))
        defer { withExtendedLifetime(library) {} }
        let memory = instance.configuration.memorySizeInGB

        // A rename admitted on a live VM carries no machine key with it.
        let renamed = try instance.activity.edit(.rename) { permit in
            permit.updateConfiguration {
                $0.name = "Renamed"
                $0.memorySizeInGB = memory.adding(gibibytes: 4)
            }
        }
        #expect(renamed.fieldsOutsidePermit == ["memorySizeInGB"])
        #expect(instance.configuration.memorySizeInGB == memory)
        #expect(instance.name != "Renamed")

        // The settings pair stops at the configuration it refused.
        let settings = try instance.activity.edit(.observations) { permit in
            permit.updateSettings(
                configuration: { $0.clipboardSharingEnabled.toggle() },
                hostState: { $0.lastFullscreenDisplayID = 3 })
        }
        #expect(settings.fieldsOutsidePermit == ["clipboardSharingEnabled"])
        #expect(instance.hostState.lastFullscreenDisplayID == nil)

        // Host state is checked the same way.
        let autoStart = try instance.activity.edit(.hostPresentation) { permit in
            library.updateHostState(permit) { $0.startsAutomaticallyOnLaunch = true }
        }
        #expect(autoStart.fieldsOutsidePermit == ["startsAutomaticallyOnLaunch"])
        #expect(!instance.hostState.startsAutomaticallyOnLaunch)

        // And the two files one class writes whole.
        #expect(throws: VMStateFieldRefusal(fields: ["pairings"])) {
            try instance.activity.edit(.snapshotMetadata) { permit in
                try permit.bundle.commitUSBPairings {
                    $0.upsert(
                        USBAccessoryPairing(
                            key: "k", form: .serialNumber, displayName: "Stick",
                            receptacleLabel: nil, pairedAt: Date(timeIntervalSince1970: 0)))
                }
            }
        }
        #expect(instance.usbPairings.isEmpty)
        #expect(throws: VMStateFieldRefusal(fields: ["snapshots"])) {
            try instance.activity.edit(.pairingRules) { permit in
                try permit.bundle.commitSnapshotManifest { $0.snapshots.removeAll() }
            }
        }
        #expect(instance.snapshotManifest.snapshots.count == 1)
    }

    @Test(
        "An observation may turn the install reminder back on and retract the guest account, but never silence or set either"
    )
    func observationsWriteOnlyWhatTheyDisprove() throws {
        let (instance, _, library) = makeWiredInstance(.running(sessionID: UUID()))
        defer { withExtendedLifetime(library) {} }

        let dismissed = try instance.activity.edit(.observations) { permit in
            library.updateHostState(permit) { $0.agentInstallNudgeDismissed = true }
        }
        #expect(dismissed.fieldsOutsidePermit == ["agentInstallNudgeDismissed"])
        library.editHostState(of: instance) { $0.agentInstallNudgeDismissed = true }
        let reset = try instance.activity.edit(.observations) { permit in
            library.updateHostState(permit) { $0.agentInstallNudgeDismissed = false }
        }
        #expect(reset.landed)
        #expect(!instance.hostState.agentInstallNudgeDismissed)

        let account = GuestAccountIntent(
            fullName: "User", username: "user", logsInAutomatically: false,
            enablesRemoteLogin: false)
        let asserted = try instance.activity.edit(.observations) { permit in
            permit.updateConfiguration { $0.pendingGuestAccount = account }
        }
        #expect(asserted.fieldsOutsidePermit == ["pendingGuestAccount"])
        #expect(instance.configuration.pendingGuestAccount == nil)
        try instance.activity.performNow(.deletingSnapshot) { context in
            #expect(context.permit.updateConfiguration { $0.pendingGuestAccount = account }.landed)
            return .rest(.asStarted, ())
        }
        let retracted = try instance.activity.edit(.observations) { library.retractGuestAccount($0) }
        #expect(retracted.landed)
        #expect(instance.configuration.pendingGuestAccount == nil)
    }

    @Test("An operation's own permit writes the VM it holds, where an edit beside it is refused")
    func anOperationsPermitWritesItsOwnVM() throws {
        let (instance, _, library) = makeWiredInstance(.running(sessionID: UUID()))
        defer { withExtendedLifetime(library) {} }

        let (authority, besideRefusal) = try instance.activity.performNow(.deletingSnapshot) {
            (context: borrowing VMOperationContext)
                -> VMOperationEnding<(VMEditPermit.Authority, VMAdmissionRefusal?)> in
            #expect(context.instance === instance)
            #expect(context.permit.instance === instance)
            var refusal: VMAdmissionRefusal?
            do {
                try instance.activity.edit(.snapshotMetadata) { _ in }
            } catch let refused as VMAdmissionRefusal {
                refusal = refused
            }
            // A machine key no settled live VM takes, written as the
            // operation's own.
            #expect(context.permit.updateConfiguration { $0.memorySizeInGB = .gibibytes(6) }.landed)
            return .rest(.asStarted, (context.permit.authority, refusal))
        }

        #expect(authority == .operation(.deletingSnapshot))
        #expect(besideRefusal == VMAdmissionRefusal(refusal: .busy(.deletingSnapshot)))
        #expect(instance.configuration.memorySizeInGB == .gibibytes(6))
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

        await #expect(throws: CancellationError.self) { try await outcome.resolved() }
        #expect(instance.phase == .initialBoot)
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
        try await outcome.resolved()

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
        await #expect(throws: removed) { try await instance.activity.requestStop { _ in } }
        #expect(throws: removed) { try instance.activity.forceStop {} }
        #expect(throws: removed) { try instance.activity.cancel(.guestSetup) }
        #expect(throws: removed) { try instance.activity.remove() }
        #expect(instance.phase == .removed)
    }

    // MARK: - Follow-ups

    /// A follow-up that launches `kind`, its body parking on `gate` when one
    /// is given, and records `label` in `order` once it is admitted.
    private func followUp(
        _ label: String, _ kind: VMOperationKind, on instance: VMInstance,
        scope: VMFollowUp.Scope = .vm, rank: VMFollowUp.Rank = .ordinary,
        request: VMAdmission.Request? = nil, gate: GatedStep? = nil, order: FollowUpOrder
    ) -> VMFollowUp {
        VMFollowUp(scope: scope, rank: rank, request: request) { outcome in
            if let nonBringUp = VMNonBringUpKind(kind) {
                try instance.activity.launch(nonBringUp, resolving: outcome) { _ in
                    try await gate?.pass()
                    return .rest(.asStarted, ())
                }
            } else if case .bringUp(let bringUp) = kind {
                try instance.activity.launchAnyBringUp(bringUp) { _ in
                    try await gate?.pass()
                    return .rest(.asStarted, ())
                }
                .forward(to: outcome)
            }
            order.admitted.append(label)
        }
    }

    /// The queue's invariant, outside a commit step: non-empty only while an
    /// operation holds the VM.
    private func expectQueueHeldByAnOperation(
        _ instance: VMInstance, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            instance.activity.queuedFollowUpCountForTesting == 0 || instance.phase.operation != nil,
            "\(instance.activity.queuedFollowUpCountForTesting) queued at \(instance.phase)",
            sourceLocation: sourceLocation)
    }

    @Test("Restorations drain before ordinary follow-ups, and each rank in arrival order")
    func restorationsFirstThenArrivalOrder() async throws {
        let (instance, _, library) = makeWiredInstance(.stopped)
        defer { withExtendedLifetime(library) {} }
        let snapshotID = try #require(instance.snapshotManifest.snapshots.first?.id)
        let order = FollowUpOrder()
        let holdGate = GatedStep()
        let hold = try launchGated(.deletingSnapshot, on: instance, gate: holdGate)
        // Gated, so the revert still holds the VM when the first drain is
        // read: ungated, it can end and drain the next before this resumes.
        let revertGate = GatedStep()
        let owed = [
            followUp("first", .copyingOut(.stopped), on: instance, order: order),
            followUp("second", .copyingOut(.stopped), on: instance, order: order),
            followUp(
                "revert", .bringUp(.reverting(snapshotID: snapshotID, resumesAfter: false)),
                on: instance, rank: .restoration, gate: revertGate, order: order),
            followUp("third", .copyingOut(.stopped), on: instance, order: order),
        ]

        for item in owed { instance.activity.follow(item) }
        #expect(instance.activity.queuedFollowUpCountForTesting == 4)

        holdGate.release()
        try await hold.resolved()
        #expect(order.admitted == ["revert"])
        revertGate.release()
        for item in owed { try await item.outcome.resolved() }
        #expect(order.admitted == ["revert", "first", "second", "third"])
        #expect(instance.phase == .stopped)
        expectQueueHeldByAnOperation(instance)
    }

    @Test("A session end drops the follow-ups scoped to it, and a follow-up for a gone session is refused")
    func aSessionEndDropsItsFollowUps() async throws {
        let session = UUID()
        let (instance, _) = makeInstance(.running(sessionID: session))
        instance.beginSessionContextForTesting()
        let order = FollowUpOrder()
        let holdGate = GatedStep()
        let hold = try launchGated(.deletingSnapshot, on: instance, gate: holdGate)
        try await holdGate.waitUntilEntered()
        let scoped = followUp("pause", .pausing, on: instance, scope: .session(session), order: order)
        let unscoped = followUp("copy", .copyingOut(.stopped), on: instance, order: order)
        instance.activity.follow(scoped)
        instance.activity.follow(unscoped)

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)

        await #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try await scoped.outcome.resolved()
        }
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        let late = followUp("late", .pausing, on: instance, scope: .session(session), order: order)
        instance.activity.follow(late)
        await #expect(throws: VMAdmissionRefusal(refusal: .invalidState)) {
            try await late.outcome.resolved()
        }
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        holdGate.release()
        try await hold.resolved()
        try await unscoped.outcome.resolved()
        #expect(order.admitted == ["copy"])
    }

    @Test("A delete ends every follow-up queued on the VM as removed, running none")
    func aDeleteDropsEveryFollowUp() async throws {
        let (instance, _) = makeInstance(.stopped)
        let order = FollowUpOrder()
        let gate = GatedStep()
        let deletion = Task { try await instance.activity.delete { _ in try await gate.pass() } }
        try await gate.waitUntilEntered()
        let owed = followUp("copy", .copyingOut(.stopped), on: instance, order: order)
        instance.activity.follow(owed)
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        gate.release()
        try await deletion.joined()

        #expect(instance.phase == .removed)
        await #expect(throws: VMAdmissionRefusal(refusal: .removed)) {
            try await owed.outcome.resolved()
        }
        let late = followUp("late", .copyingOut(.stopped), on: instance, order: order)
        instance.activity.follow(late)
        await #expect(throws: VMAdmissionRefusal(refusal: .removed)) {
            try await late.outcome.resolved()
        }
        #expect(order.admitted.isEmpty)
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
    }

    @Test("Follow-ups queued behind one the drain admits join it where its operation declares the join")
    func queuedFollowUpsJoinTheDrainedOne() async throws {
        let session = UUID()
        let (instance, _) = makeInstance(.running(sessionID: session))
        instance.beginSessionContextForTesting()
        let order = FollowUpOrder()
        let holdGate = GatedStep()
        let hold = try launchGated(.pausing, on: instance, gate: holdGate)
        let passGate = GatedStep()
        // Scoped differently, so the second queues rather than joining the
        // first in the queue.
        let first = followUp(
            "first", .reconcilingMedia, on: instance, scope: .vm,
            request: .operation(.reconcilingMedia), gate: passGate, order: order)
        let second = followUp(
            "second", .reconcilingMedia, on: instance, scope: .session(session),
            request: .operation(.reconcilingMedia), order: order)
        instance.activity.follow(first)
        instance.activity.follow(second)
        #expect(instance.activity.queuedFollowUpCountForTesting == 2)

        holdGate.release()
        try await hold.resolved()
        #expect(order.admitted == ["first"])
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        expectQueueHeldByAnOperation(instance)

        passGate.release()
        try await second.outcome.resolved()
        #expect(order.admitted == ["first"])
        #expect(instance.phase == .running(sessionID: session))
    }

    @Test("A follow-up making a queued one's request in its scope joins it rather than queueing twice")
    func aDuplicateFollowUpJoinsTheQueuedOne() async throws {
        let session = UUID()
        let (instance, _) = makeInstance(.running(sessionID: session))
        instance.beginSessionContextForTesting()
        let order = FollowUpOrder()
        let holdGate = GatedStep()
        let hold = try launchGated(.deletingSnapshot, on: instance, gate: holdGate)
        let request = VMAdmission.Request.operation(.attachingUSB(registryID: 7))
        let passGate = GatedStep()
        let first = followUp(
            "first", .pausing, on: instance, scope: .session(session), request: request,
            gate: passGate, order: order)
        let duplicate = followUp(
            "duplicate", .pausing, on: instance, scope: .session(session), request: request,
            order: order)
        let elsewhere = followUp(
            "elsewhere", .pausing, on: instance, scope: .vm, request: request, order: order)

        instance.activity.follow(first)
        instance.activity.follow(duplicate)
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        // The same request in another scope is another follow-up.
        instance.activity.follow(elsewhere)
        #expect(instance.activity.queuedFollowUpCountForTesting == 2)
        instance.activity.withdraw(elsewhere)

        holdGate.release()
        try await hold.resolved()
        #expect(order.admitted == ["first"])
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        passGate.release(throwing: Probe())
        await #expect(throws: Probe.self) { try await first.outcome.resolved() }
        await #expect(throws: Probe.self) { try await duplicate.outcome.resolved() }
        #expect(order.admitted == ["first"])
    }

    @Test("Only a failure of the work itself is reported")
    func onlyAFailureOfTheWorkIsReported() {
        let session = VMFollowUp.Scope.session(UUID())
        let silent: [(any Error, VMFollowUp.Scope)] = [
            (VMAdmissionRefusal(refusal: .removed), .vm),
            (VMAdmissionRefusal(refusal: .terminating), .vm),
            (CancellationError(), .vm),
            (VMAdmissionRefusal(refusal: .invalidState), session),
        ]
        for (error, scope) in silent {
            #expect(!VMFollowUp.isReportable(error, scope: scope), "\(error) \(scope)")
        }
        let reported: [(any Error, VMFollowUp.Scope)] = [
            (VMAdmissionRefusal(refusal: .invalidState), .vm),
            (VMAdmissionRefusal(refusal: .heldByAnotherCopy), .vm),
            (VMAdmissionRefusal(refusal: .usbPassthroughUnavailable(.needsEntitlement)), session),
            (Probe(), session),
        ]
        for (error, scope) in reported {
            #expect(VMFollowUp.isReportable(error, scope: scope), "\(error) \(scope)")
        }
    }

    // MARK: - Session events

    @Test("A settled session end rests the VM, and only a power-off fires the power-off hook")
    func settledSessionEndRestsTheVM() throws {
        let session = UUID()
        let message = Probe().localizedDescription
        let cases: [(VMLifecyclePhase, VMSessionEvent, VMLifecyclePhase, Int)] = [
            (.running(sessionID: session), .guestDidStop, .stopped, 1),
            (.livePaused(sessionID: session), .guestDidStop, .stopped, 1),
            (.running(sessionID: session), .didStopWithError(Probe()), .failed(message: message), 1),
            (.livePaused(sessionID: session), .didStopWithError(Probe()), .failed(message: message), 1),
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
            #expect(recorder.settled == powerOffs, "\(phase) \(event)")
        }
    }

    // MARK: - Force Stop

    @Test("A Force Stop of a settled VM whose stop fails ends back where it started, for every caller")
    func failedTerminationOfASettledStopRestsLive() async throws {
        let session = UUID()
        let (instance, recorder) = makeInstance(.running(sessionID: session))

        let first = try instance.activity.forceStop { recorder.terminations += 1 }
        #expect(instance.phase.operation?.kind == .forceStopping)
        let second = try instance.activity.forceStop { recorder.terminations += 1 }
        #expect(second === first)

        instance.activity.deliverSessionEvent(.stopDidFail(Probe()), from: session)
        await #expect(throws: Probe.self) { try await first.resolved() }
        await #expect(throws: Probe.self) { try await second.resolved() }
        #expect(recorder.terminations == 1)
        #expect(instance.phase == .running(sessionID: session))
        #expect(recorder.settled == 0)
    }

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

    @Test("A Force Stop presents as Force Stopping, as its own operation and on the session of one that tolerated it")
    func forceStopPresentsItsOwnStatus() async throws {
        let session = UUID()
        let (instance, _, library) = makeWiredInstance(.running(sessionID: session))
        defer { withExtendedLifetime(library) {} }
        let gate = GatedStep()
        let pause = try launchGated(.pausing, on: instance, gate: gate)
        try await gate.waitUntilEntered()
        #expect(instance.status == .running)

        let stop = try instance.activity.forceStop {}
        #expect(instance.phase.operation?.kind == .pausing)
        #expect(instance.status == .forceStopping)
        #expect(!instance.hasActiveDisplay)

        // The pause ends on a session still stopping, which hands the VM to
        // the Force Stop's own operation: still Force Stopping.
        gate.release()
        try await pause.resolved()
        #expect(instance.phase.operation?.kind == .forceStopping)
        #expect(instance.status == .forceStopping)

        instance.activity.deliverSessionEvent(.stopDidComplete, from: session)
        try await stop.resolved()
        #expect(instance.status == .stopped)
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

    @Test("An operation's stop of its own session returns on the stop's completion, and throws its failure")
    func operationStopAnswersItsCompletion() async throws {
        for fails in [false, true] {
            let session = UUID()
            let (instance, _) = makeInstance(.running(sessionID: session))
            let recorder = StopRecordingSession(id: session)
            instance.beginSessionContextForTesting().session = recorder

            let outcome = try instance.activity.launch(.deletingSnapshot) { context in
                do {
                    try await context.stopSession()
                } catch {
                    #expect(context.sessionID == session)
                    return .failed(.asStarted, error)
                }
                // Ended by the completion itself, as the operation's own.
                #expect(context.sessionID == nil)
                #expect(context.sessionEnd == .endedByOperation)
                return .rest(.afterSessionEnd, ())
            }
            try await recorder.stopped.wait { recorder.stops == 1 }
            instance.activity.deliverSessionEvent(fails ? .stopDidFail(Probe()) : .stopDidComplete, from: session)

            if fails {
                await #expect(throws: Probe.self) { try await outcome.resolved() }
                #expect(instance.phase == .running(sessionID: session))
            } else {
                try await outcome.resolved()
                #expect(instance.phase == .stopped)
            }
        }
    }

    @Test(
        "A revert whose stop never completes shows how to end the VM's process, and goes on when it ends",
        arguments: ProcessEndArrival.allCases)
    func revertStopShowsTheProcessEnd(_ arrival: ProcessEndArrival) async throws {
        let session = UUID()
        let (instance, hooks, library) = makeWiredInstance(.running(sessionID: session))
        defer { withExtendedLifetime(library) {} }
        let recorder = StopRecordingSession(id: session)
        instance.beginSessionContextForTesting().session = recorder
        let snapshotID = try #require(instance.snapshotManifest.snapshots.first?.id)
        instance.activity.onSessionStoppedWithError = { hooks.stoppedWithError.append($0) }

        let outcome = try instance.activity.launchAnyBringUp(
            .reverting(snapshotID: snapshotID, resumesAfter: false)
        ) { context in
            try await context.operation.stopSession()
            return .rest(.atRest(.stopped), ())
        }
        try await recorder.stopped.wait { recorder.stops == 1 }
        #expect(instance.status == .restoring)
        #expect(instance.processEndInstruction != nil)
        #expect(!instance.hasActiveDisplay)

        // Ending the process from outside, as the instruction says, raises
        // `didStopWithError` — and, where the stop's completion runs at all,
        // that completion, which can land first.
        if arrival == .completionThenDelegate {
            // The session ends with the completion: no live session is left
            // for a display to show, or for the delegate's event to end again.
            instance.activity.deliverSessionEvent(.stopDidComplete, from: session)
            #expect(!instance.hasLiveVirtualMachine)
            #expect(instance.session == nil)
        }
        instance.activity.deliverSessionEvent(.didStopWithError(Probe()), from: session)
        try await outcome.resolved()
        #expect(instance.processEndInstruction == nil)
        #expect(instance.phase == .stopped)
        #expect(instance.activity.lastFailure == nil)
        #expect(hooks.stoppedWithError.isEmpty)
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

    // MARK: - Binding a session

    @Test("A bring-up's bound session is the operation's, and the rest it commits")
    func bindSessionBindsToTheBringUp() async throws {
        let (instance, recorder) = makeInstance(.stopped)
        let session = UUID()

        try await instance.activity.launchAnyBringUp(.guestStart(.starting(recovery: false))) { context in
            recorder.sessionID = context.operation.sessionID
            #expect(instance.liveSessionID == nil)
            context.bindSessionForTesting(session)
            #expect(context.operation.sessionID == session)
            #expect(instance.phase.operation?.session == VMOperationSession(id: session, guest: .running))
            #expect(instance.liveSessionID == session)
            return .rest(.live(.running), ())
        }.resolved()

        #expect(recorder.sessionID == nil)
        #expect(instance.phase == .running(sessionID: session))
    }
}

/// The labels of the follow-ups a test queued, in the order each was admitted.
@MainActor
private final class FollowUpOrder {
    var admitted: [String] = []
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

/// What reaches a VM whose process the user ended from outside while a stop
/// of it was pending.
enum ProcessEndArrival: CaseIterable, Sendable {
    /// `didStopWithError` alone: the stop's completion never runs.
    case delegateOnly
    /// The stop's completion, reporting the session ended, then
    /// `didStopWithError`.
    case completionThenDelegate
}

/// The ways Virtualization can end a session a Force Stop is waiting on before
/// the stop's completion arrives, if it ever does.
enum SessionEndUnderAStop: CaseIterable, Sendable {
    /// `didStopWithError` — what killing the VM's process raises.
    case stoppedWithError
    /// `guestDidStop`.
    case guestStopped
}
