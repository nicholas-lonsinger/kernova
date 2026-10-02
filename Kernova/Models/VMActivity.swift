import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// Where a VM is in its lifecycle, the live session it holds, and the one
/// place any request on it is admitted and committed.
///
/// The only writer of ``phase`` and ``sessionContext``. The phase moves only at
/// an operation's admission commit, at its ending, at a Force Stop's admission
/// and its completion, and on a session event; each of those is one
/// synchronous step, so no decision can read a phase another request is about
/// to replace.
///
/// Also the only holder of the VM's bundle run lock, which it holds exactly
/// while the VM is neither at rest nor removed: ``admit(_:origin:identity:outcome:)``
/// takes it as an operation leaves rest, and the tail of every ending lets it
/// go once the VM rests again, so no other copy of Kernova acts on a VM this
/// one holds.
///
/// And the only holder of the VM's queue of ``VMFollowUp``s, which is non-empty
/// outside a commit step only while an operation holds the VM: a follow-up on a
/// settled VM drains at once, and the tail of every step that settles the VM
/// drains the rest — so a queued follow-up always gets the freed VM before any
/// other request can be decided against it.
@MainActor
@Observable
final class VMActivity {
    /// The VM this activity belongs to, which every context and permit it
    /// mints names.
    ///
    /// Set by the owner as it is created.
    @ObservationIgnored weak var owner: VMInstance?

    private(set) var phase: VMLifecyclePhase

    /// Counts every write of ``phase``, so a reader can tell the VM moved
    /// even when an operation left it in the phase it started from.
    private(set) var phaseCommits = 0

    /// Everything scoped to the current `VZVirtualMachine`'s lifetime, bound to
    /// the session ``VMLifecyclePhase/sessionID`` names.
    private(set) var sessionContext: VMSessionContext?

    /// The live VM's isolation domain — the only type that calls into the
    /// `VZVirtualMachine` and its device objects.
    var session: VMSession? { sessionContext?.session }

    var status: VMStatus { phase.status }

    var errorMessage: String? { phase.errorMessage }

    /// Whose copy of Kernova holds the VM's bundle run lock, as this copy last
    /// learned it — written only through ``setHold(_:)``.
    @ObservationIgnored private var hold: VMRunLockHold = .none

    /// Whether this copy holds the VM's bundle run lock: exactly while the VM
    /// is neither at rest nor removed.
    var holdsRunLock: Bool { hold.isThisCopy }

    /// Whether this copy last found another copy of Kernova holding the VM's
    /// run lock — by a lock attempt, a commit's probe, a refused write or a
    /// ``refreshFromBundle()`` — only ever while the VM is at rest here.
    var heldByAnotherCopy: Bool {
        access(keyPath: \.heldByAnotherCopy)
        return hold.isAnotherCopy
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMActivity")

    init(phase: VMLifecyclePhase) {
        self.phase = phase
    }

    private var name: String { owner?.name ?? "" }

    // MARK: - Hooks

    /// Fired when a power-off has rested the VM — immediately for a settled
    /// VM, and at the ending of the operation that held it otherwise —
    /// answering the follow-ups the power-off owes, which the same step
    /// drains.
    ///
    /// Wired by `VMLibrary.wireHooks(for:)`, whose handler answers an
    /// Ephemeral Mode VM's baseline revert.
    @ObservationIgnored var onPoweredOff: (@MainActor () -> [VMFollowUp])?

    /// Fired on the edge where this VM becomes something a device can be
    /// attached to — ``attachableSessionID`` going from `nil` to naming a
    /// session — so it fires once per session, answering the follow-ups the
    /// edge owes.
    ///
    /// Wired by `VMLibrary.wireHooks(for:)`.
    @ObservationIgnored var onSessionBecameAttachable: (@MainActor () -> [VMFollowUp])?

    /// Runs at an operation's ending commit, after the VM rests and before
    /// the outcome resolves, answering the follow-ups the ending owes.
    typealias WhenEnded = @MainActor (Result<Void, any Error>) -> [VMFollowUp]

    // MARK: - Follow-ups

    /// The follow-ups owed to this VM, restorations first and each rank in
    /// arrival order.
    @ObservationIgnored private var followUps: [VMFollowUp] = []

    /// The follow-ups owed once a session ends, each with the session it
    /// waits on, in arrival order — queued by the step that settles the VM
    /// after that session is gone.
    @ObservationIgnored private var sessionEndFollowUps: [(session: UUID, followUp: VMFollowUp)] = []

    /// Queues `followUp` and, on a settled VM, drains it at once.
    ///
    /// One scoped to a session that is no longer live ends refused as
    /// ``VMAdmission/Refusal/invalidState`` without being queued, and one the
    /// operation holding the VM joins, or one making the request a queued
    /// follow-up already makes, takes that outcome instead.
    func follow(_ followUp: VMFollowUp) {
        enqueue([followUp])
        drain()
    }

    /// Owes `followUp` to the end of the session `sessionID` names: the step
    /// that settles the VM once that session is gone queues it — behind a
    /// restoration its power-off owes — and drains it, before any other
    /// request can be decided against the VM.
    ///
    /// Ends refused as ``VMAdmission/Refusal/invalidState`` at once when that
    /// session is not live.
    func follow(_ followUp: VMFollowUp, whenSessionEnds sessionID: UUID) {
        guard sessionID == liveSessionID else {
            followUp.outcome.resolve(.failure(followUpRefusal(.invalidState, for: followUp)))
            return
        }
        sessionEndFollowUps.append((sessionID, followUp))
    }

    /// Takes `followUp` off the queue, or off what a session end owes,
    /// resolving its outcome with `CancellationError` — answering whether it
    /// did, which it does not once the follow-up has drained.
    @discardableResult
    func withdraw(_ followUp: VMFollowUp) -> Bool {
        if let index = followUps.firstIndex(where: { $0.outcome === followUp.outcome }) {
            followUps.remove(at: index).outcome.resolve(.failure(CancellationError()))
            return true
        }
        if let index = sessionEndFollowUps.firstIndex(where: { $0.followUp.outcome === followUp.outcome }) {
            sessionEndFollowUps.remove(at: index).followUp.outcome.resolve(.failure(CancellationError()))
            return true
        }
        return false
    }

    /// Takes off what the sessions that are no longer live owe — for the
    /// step settling the VM to queue.
    private func takeSessionEndFollowUps() -> [VMFollowUp] {
        let live = liveSessionID
        let due = sessionEndFollowUps.filter { $0.session != live }
        guard !due.isEmpty else { return [] }
        sessionEndFollowUps.removeAll { $0.session != live }
        return due.map(\.followUp)
    }

    /// Queues `items` behind every follow-up of their rank or better, without
    /// draining: the step that queues them drains once it has settled.
    private func enqueue(_ items: [VMFollowUp]) {
        for item in items {
            if case .session(let id) = item.scope, id != liveSessionID {
                item.outcome.resolve(.failure(followUpRefusal(.invalidState, for: item)))
                continue
            }
            if joinsHolder(item) || joinsQueued(item) { continue }
            let index = followUps.firstIndex { $0.rank > item.rank } ?? followUps.endIndex
            followUps.insert(item, at: index)
        }
    }

    /// Admits the queue's head while the VM stays settled, each decided
    /// afresh against the phase it meets: an admitted follow-up holds the VM,
    /// which ends the drain, and a refused one resolves its outcome with the
    /// refusal. A removed VM refuses every one as
    /// ``VMAdmission/Refusal/removed``. Whatever is still queued once a
    /// follow-up holds the VM joins it where its operation declares the join.
    private func drain() {
        while phase.isSettled, !followUps.isEmpty {
            let head = followUps.removeFirst()
            guard phase != .removed else {
                head.outcome.resolve(.failure(followUpRefusal(.removed, for: head)))
                continue
            }
            do {
                try head.admit(head.outcome)
            } catch {
                head.outcome.resolve(.failure(error))
            }
        }
        guard phase.operation != nil else { return }
        var waiting: [VMFollowUp] = []
        for item in followUps where !joinsHolder(item) {
            waiting.append(item)
        }
        followUps = waiting
    }

    /// Hands `followUp` the outcome of the operation holding the VM when
    /// admission decides its ``VMFollowUp/request`` joins that operation,
    /// answering whether it did.
    private func joinsHolder(_ followUp: VMFollowUp) -> Bool {
        guard let request = followUp.request, let holder = phase.operation,
            case .join(let running) = decide(request, posture: .commit)
        else { return false }
        running.forward(to: followUp.outcome)
        #log(
            Self.logger, .notice,
            "A follow-up on '\(self.name, privacy: .public)' joined the \(String(describing: holder.kind), privacy: .public) holding it"
        )
        return true
    }

    /// Hands `followUp` the outcome of the queued follow-up making the same
    /// ``VMFollowUp/request`` in the same scope, answering whether one was
    /// queued.
    private func joinsQueued(_ followUp: VMFollowUp) -> Bool {
        guard let request = followUp.request,
            let queued = followUps.first(where: {
                $0.request == request && $0.scope == followUp.scope
            })
        else { return false }
        queued.outcome.forward(to: followUp.outcome)
        #log(
            Self.logger, .notice,
            "A follow-up on '\(self.name, privacy: .public)' joined the queued one making the same request"
        )
        return true
    }

    /// Ends every follow-up scoped to a session, as the one live session ends.
    private func dropSessionFollowUps() {
        let dropped = followUps.filter { $0.scope != .vm }
        guard !dropped.isEmpty else { return }
        followUps.removeAll { $0.scope != .vm }
        for item in dropped {
            item.outcome.resolve(.failure(followUpRefusal(.invalidState, for: item)))
        }
    }

    private func followUpRefusal(
        _ reason: VMAdmission.Refusal, for followUp: VMFollowUp
    ) -> VMAdmissionRefusal {
        #log(
            Self.logger, .notice,
            "Dropped a follow-up scoped to \(String(describing: followUp.scope), privacy: .public) on '\(self.name, privacy: .public)': \(String(describing: reason), privacy: .public)"
        )
        return VMAdmissionRefusal(refusal: reason)
    }

    #if DEBUG
    /// How many follow-ups are queued; tests only.
    var queuedFollowUpCountForTesting: Int { followUps.count }
    #endif

    // MARK: - Liveness

    /// The live session's identity — the token every asynchronous hand-off and
    /// delivered event carries, so one raised against a released session is
    /// dropped.
    var liveSessionID: UUID? { phase.sessionID }

    var hasLiveVirtualMachine: Bool { liveSessionID != nil }

    var hasLiveSession: Bool { phase.hasLiveSession }

    /// The session a removable-media attach or detach acts on, or `nil` when
    /// the VM presents none.
    var attachableSessionID: UUID? { hasLiveSession ? liveSessionID : nil }

    var isSuspended: Bool { phase.presented == .suspended }

    var isLivePaused: Bool { phase.isLivePaused }

    var holdsLiveIdentity: Bool { phase.holdsLiveIdentity }

    var isAtRest: Bool { phase.isAtRest }

    /// Whether this VM should keep the app alive: an operation holds it, or a
    /// `VZVirtualMachine` is in memory.
    var isKeepingAppAlive: Bool { phase.operation != nil || hasLiveVirtualMachine }

    var hasActiveDisplay: Bool { phase.hasActiveDisplay }

    /// Where this VM rests once nothing is live: suspended while its suspend
    /// slot is on disk, `fallback` once it is not.
    func restingPhase(withoutSlot fallback: VMRestPhase) -> VMLifecyclePhase {
        fallback.phase(slotOnDisk: owner?.hasSaveFile == true)
    }

    // MARK: - Admission

    /// How a request on this VM is decided right now.
    ///
    /// The catalog's answers and every commit below read this, so an offer and
    /// the commit it leads to agree.
    ///
    /// A commit asks the bundle whether another copy holds it rather than
    /// reading what the last lock attempt found, and records the answer, so a
    /// hold that has since ended refuses nothing and every offer after it
    /// reads what the commit found.
    ///
    /// `identity` is what the request can do about another active VM sharing
    /// the machine identity a committed bring-up would claim; an offer checks
    /// no identity.
    func decide(
        _ request: VMAdmission.Request, origin: VMRequestOrigin = .newWork,
        posture: VMAdmission.Posture, identity: VMIdentityOverride = .unavailable
    ) -> VMAdmission.Decision {
        decide(
            request, origin: origin, posture: posture, identity: identity,
            probingOtherCopies: posture == .commit)
    }

    /// ``decide(_:origin:posture:identity:)``, asking the bundle whether
    /// another copy holds it — and recording the answer — when
    /// `probingOtherCopies`, and reading the last recorded answer otherwise.
    private func decide(
        _ request: VMAdmission.Request, origin: VMRequestOrigin, posture: VMAdmission.Posture,
        identity: VMIdentityOverride, probingOtherCopies: Bool
    ) -> VMAdmission.Decision {
        guard let owner else { return .refuse(.invalidState) }
        if probingOtherCopies, !hold.isThisCopy,
            VMAdmission.isRefusedWhileHeldByAnotherCopy(request, phase: phase)
        {
            recordOtherCopyHold(heldElsewhere: owner.bundle.isRunLockedElsewhere())
        }
        var facts = owner.admissionFacts
        if posture == .commit,
            let kind = VMAdmission.bringUpKind(for: request, phase: phase, facts: facts),
            kind.checksIdentity
        {
            facts.identityConflict = owner.identityConflict(for: kind, override: identity)
        }
        if case .operation(.attachingUSB(let registryID)) = request {
            facts.accessoryHolder = accessoryHolders?.holder(of: registryID)
        }
        return VMAdmission.decide(
            request, origin: origin, posture: posture, phase: phase, facts: facts)
    }

    /// How `request` would be decided once the saved state is discarded — so
    /// work that follows a discard is known to be admitted before the
    /// irreversible step is taken.
    func decideAsIfSavedStateDiscarded(
        _ request: VMAdmission.Request, posture: VMAdmission.Posture
    ) -> VMAdmission.Decision {
        guard let owner else { return .refuse(.invalidState) }
        let counterfactual: VMLifecyclePhase = phase == .suspended ? .stopped : phase
        return VMAdmission.decide(
            request, posture: posture, phase: counterfactual,
            facts: owner.admissionFacts.discardingSavedState())
    }

    /// Throws the refusal unless `request` is admitted outright, answering the
    /// VM it was admitted on.
    @discardableResult
    private func requireAdmitted(
        _ request: VMAdmission.Request, origin: VMRequestOrigin = .newWork,
        identity: VMIdentityOverride = .unavailable, probingOtherCopies: Bool = true
    ) throws -> VMInstance {
        guard let owner else { throw VMAdmissionRefusal(refusal: .invalidState) }
        switch decide(
            request, origin: origin, posture: .commit, identity: identity,
            probingOtherCopies: probingOtherCopies)
        {
        case .admit:
            return owner
        case .join:
            throw VMAdmissionRefusal(refusal: phase.operation.map { .busy($0.kind) } ?? .invalidState)
        case .refuse(let reason):
            throw VMAdmissionRefusal(refusal: reason)
        }
    }

    // MARK: - Edits

    /// Admits a write of `classes` to the VM's state files and runs `write`
    /// with the permit admission minted for it.
    ///
    /// `write` is synchronous, so the phase that admitted it is the phase it
    /// writes under.
    @discardableResult
    func edit<T>(
        _ classes: VMEditClasses, _ write: (borrowing VMEditPermit) throws -> T
    ) throws -> T {
        let owner = try requireAdmitted(.edit(classes))
        return try write(VMEditPermit(instance: owner, authority: .edit(classes)))
    }

    // MARK: - Operations

    /// Admits `kind`, commits it, runs `body` under its context, and commits
    /// where the body leaves the VM — the whole of one operation.
    ///
    /// A body that throws rests the VM where its kind's
    /// ``VMOperationKind/restAfterFailure(_:)`` says.
    func perform<T>(
        _ kind: VMNonBringUpKind, origin: VMRequestOrigin = .newWork,
        _ body: (borrowing VMOperationContext) async throws -> VMOperationEnding<T>
    ) async throws -> T {
        try await run(kind.operationKind, origin: origin, { $0 }, body)
    }

    /// ``perform(_:origin:_:)`` for a snapshot capture, whose body learns the mode it
    /// was admitted in from its context.
    func captureSnapshot<T>(
        _ mode: VMCaptureMode,
        _ body: (borrowing VMCaptureContext) async throws -> VMOperationEnding<T>
    ) async throws -> T {
        try await run(
            .capturingSnapshot(mode), { VMCaptureContext(operation: $0, mode: mode) }, body)
    }

    /// ``perform(_:origin:_:)`` for the attach of the accessory `registryID`
    /// names, whose body passes it through under the reservation its
    /// admission wrote.
    func attachUSBAccessory<T>(
        _ registryID: UInt64,
        _ body: (borrowing VMUSBAttachContext) async throws -> VMOperationEnding<T>
    ) async throws -> T {
        try await run(
            .attachingUSB(registryID: registryID), { Self.usbAttachContext(registryID, $0) }, body)
    }

    /// The attach context for `registryID` over `operation`, whose admission
    /// reserved the accessory.
    private static func usbAttachContext(
        _ registryID: UInt64, _ operation: consuming VMOperationContext
    ) -> VMUSBAttachContext {
        let instance = operation.instance
        return VMUSBAttachContext(
            operation: operation,
            reservation: VMAccessoryReservation(registryID: registryID, instance: instance))
    }

    /// Admits `kind`, commits it, runs `body` under the context `makeContext`
    /// builds from the operation's, and commits where the body leaves the VM.
    private func run<Context: ~Copyable, T>(
        _ kind: VMOperationKind, origin: VMRequestOrigin = .newWork,
        _ makeContext: (consuming VMOperationContext) -> Context,
        _ body: (borrowing Context) async throws -> VMOperationEnding<T>
    ) async throws -> T {
        let outcome = VMOutcome()
        let owner = try admit(kind, origin: origin, outcome: outcome)
        let context = makeContext(VMOperationContext(activity: self, kind: kind, owner: owner))
        let ending: VMOperationEnding<T>
        do {
            ending = try await body(context)
        } catch {
            ending = .failed(kind.restAfterFailure(error), error)
        }
        return try finish(ending, outcome: outcome).get()
    }

    /// ``perform(_:origin:_:)`` for an operation no caller waits on: admitted and
    /// committed before this returns, its body run in a task the operation
    /// owns, and its end reported through the outcome.
    ///
    /// The operation resolves `outcome` — a follow-up's premade one, or a
    /// fresh one.
    ///
    /// `whenEnded` runs at the ending commit, after the VM rests and before the
    /// outcome resolves — so it reads the phase the operation left, and whoever
    /// awaits the outcome finds its work done.
    @discardableResult
    func launch(
        _ kind: VMNonBringUpKind, origin: VMRequestOrigin = .newWork,
        resolving outcome: VMOutcome = VMOutcome(), whenEnded: WhenEnded? = nil,
        _ body: @escaping @MainActor (borrowing VMOperationContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        try launchRun(
            kind.operationKind, origin: origin, outcome: outcome, whenEnded: whenEnded, { $0 }, body)
    }

    /// ``launch(_:origin:resolving:whenEnded:_:)`` for a bring-up that starts
    /// no guest — a guest setup.
    @discardableResult
    func launchBringUp(
        _ kind: VMNonStartBringUpKind, identity: VMIdentityOverride = .unavailable,
        whenEnded: WhenEnded? = nil,
        _ body: @escaping @MainActor (borrowing VMBringUpContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        try launchRun(
            .bringUp(kind.bringUpKind), identity: identity, outcome: VMOutcome(),
            whenEnded: whenEnded,
            { VMBringUpContext(operation: $0) }, body)
    }

    /// ``launch(_:origin:resolving:whenEnded:_:)`` for a guest start, whose
    /// body learns which start it was admitted as from its context.
    @discardableResult
    func launchStartGuest(
        _ kind: VMGuestStartKind, identity: VMIdentityOverride = .unavailable,
        resolving outcome: VMOutcome = VMOutcome(),
        _ body: @escaping @MainActor (borrowing VMGuestStartContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        try launchRun(
            .bringUp(.guestStart(kind)), identity: identity, outcome: outcome, whenEnded: nil,
            { VMGuestStartContext(bringUp: VMBringUpContext(operation: $0), kind: kind) }, body)
    }

    /// ``launch(_:origin:resolving:whenEnded:_:)`` for a revert to `snapshot`,
    /// resuming the guest at its end when `resumesAfter`.
    @discardableResult
    func launchRevert(
        to snapshot: VMSnapshot, resumesAfter: Bool, origin: VMRequestOrigin = .newWork,
        identity: VMIdentityOverride = .unavailable, resolving outcome: VMOutcome = VMOutcome(),
        _ body: @escaping @MainActor (borrowing VMRevertContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        try launchRun(
            .bringUp(.reverting(snapshotID: snapshot.id, resumesAfter: resumesAfter)),
            origin: origin, identity: identity, outcome: outcome, whenEnded: nil,
            {
                VMRevertContext(
                    bringUp: VMBringUpContext(operation: $0), snapshot: snapshot,
                    resumesAfter: resumesAfter)
            }, body)
    }

    /// ``launch(_:origin:resolving:whenEnded:_:)`` for a clone's copy out of the
    /// bundle in `mode`, whose body learns the mode from its context and
    /// captures with it as a snapshot capture does.
    @discardableResult
    func launchCopyOut(
        _ mode: VMCaptureMode,
        _ body: @escaping @MainActor (borrowing VMCaptureContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        try launchRun(
            .copyingOut(mode), outcome: VMOutcome(), whenEnded: nil,
            { VMCaptureContext(operation: $0, mode: mode) }, body)
    }

    /// ``launch(_:origin:resolving:whenEnded:_:)`` for the attach of the accessory
    /// `registryID` names — ``attachUSBAccessory(_:_:)`` in a task the
    /// operation owns.
    @discardableResult
    func launchUSBAccessoryAttach(
        _ registryID: UInt64, resolving outcome: VMOutcome,
        _ body: @escaping @MainActor (borrowing VMUSBAttachContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        try launchRun(
            .attachingUSB(registryID: registryID), outcome: outcome, whenEnded: nil,
            { Self.usbAttachContext(registryID, $0) }, body)
    }

    /// ``run(_:origin:_:_:)`` in a task the operation owns.
    private func launchRun<Context: ~Copyable>(
        _ kind: VMOperationKind, origin: VMRequestOrigin = .newWork,
        identity: VMIdentityOverride = .unavailable, outcome: VMOutcome,
        whenEnded: WhenEnded?,
        _ makeContext: @escaping @MainActor (consuming VMOperationContext) -> Context,
        _ body: @escaping @MainActor (borrowing Context) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        let owner = try admit(kind, origin: origin, identity: identity, outcome: outcome)
        outcome.task = Task { @MainActor in
            let context = makeContext(VMOperationContext(activity: self, kind: kind, owner: owner))
            let ending: VMOperationEnding<Void>
            do {
                ending = try await body(context)
            } catch {
                ending = .failed(kind.restAfterFailure(error), error)
            }
            _ = self.finish(ending, outcome: outcome, whenEnded: whenEnded)
        }
        return outcome
    }

    /// ``perform(_:origin:_:)`` for an operation with nothing to await.
    func performNow<T>(
        _ nonBringUp: VMNonBringUpKind,
        _ body: (borrowing VMOperationContext) throws -> VMOperationEnding<T>
    ) throws -> T {
        let kind = nonBringUp.operationKind
        let outcome = VMOutcome()
        let owner = try admit(kind, origin: .newWork, outcome: outcome)
        let context = VMOperationContext(activity: self, kind: kind, owner: owner)
        let ending: VMOperationEnding<T>
        do {
            ending = try body(context)
        } catch {
            ending = .failed(kind.restAfterFailure(error), error)
        }
        return try finish(ending, outcome: outcome).get()
    }

    /// Deletes the VM: admits and commits ``VMOperationKind/deleting``, runs
    /// `body` under its context, and moves the VM to
    /// ``VMLifecyclePhase/removed`` once the body returns — the only ending
    /// that removes a VM — answering what the body returned.
    ///
    /// A body that throws rests the VM where the kind's
    /// ``VMOperationKind/restAfterFailure(_:)`` says.
    func delete<T>(_ body: (borrowing VMOperationContext) async throws -> T) async throws -> T {
        let outcome = VMOutcome()
        let owner = try admit(.deleting, origin: .newWork, outcome: outcome)
        let context = VMOperationContext(activity: self, kind: .deleting, owner: owner)
        let value: T
        do {
            value = try await body(context)
        } catch {
            let ending = VMOperationEnding<T>.failed(
                VMOperationKind.deleting.restAfterFailure(error), error)
            return try finish(ending, outcome: outcome).get()
        }
        guard endingOperation(outcome) != nil else { return value }
        if sessionContext != nil { releaseSession() }
        setPhase(.removed)
        outcome.resolve(.success(()))
        settled(poweredOff: false)
        return value
    }

    /// The one admission step every operation takes, in one synchronous step:
    /// takes the run lock of a VM at rest and re-reads its bundle, decides
    /// against what that read found, reserves what `kind` claims beyond this
    /// VM, and commits.
    ///
    /// The committed operation resolves `outcome`.
    ///
    /// Throws, committing nothing and letting go of a lock it took, when the
    /// request is refused — as ``VMAdmission/Refusal/heldByAnotherCopy`` when
    /// another copy of Kernova holds the lock.
    private func admit(
        _ kind: VMOperationKind, origin: VMRequestOrigin,
        identity: VMIdentityOverride = .unavailable, outcome: VMOutcome
    ) throws -> VMInstance {
        let request = VMAdmission.Request.operation(kind)
        guard let owner else { throw VMAdmissionRefusal(refusal: .invalidState) }
        let tookLock = try takeRunLock(on: owner)
        do {
            // The lock attempt just made is read rather than probed again: a
            // hold that ended since would admit a VM this copy does not hold.
            try requireAdmitted(
                request, origin: origin, identity: identity, probingOtherCopies: false)
            try reserve(for: kind, on: owner)
        } catch {
            if tookLock { setHold(.none) }
            throw error
        }
        commitOperation(kind, outcome: outcome)
        return owner
    }

    /// Takes the run lock of a VM at rest that holds none, then re-reads its
    /// bundle and where it rests — what another copy may have changed while
    /// this one held nothing — answering whether it took one.
    ///
    /// A lock another copy holds is recorded as ``VMRunLockHold/anotherCopy``,
    /// which the decision that follows refuses. A VM already holding the lock
    /// — an operation an ending's hook begins — keeps it and re-reads nothing:
    /// no other copy can have written its bundle since.
    private func takeRunLock(on owner: VMInstance) throws -> Bool {
        guard phase.isAtRest, !hold.isThisCopy else { return false }
        guard let lock = try owner.bundle.lockRun() else {
            setHold(.anotherCopy)
            return false
        }
        setHold(.thisCopy(lock))
        do {
            try owner.bundle.refresh()
        } catch {
            setHold(.none)
            throw error
        }
        reconcileRest()
        return true
    }

    /// Lets go of the run lock once the VM rests or is removed — the other
    /// half of the rule ``admit(_:origin:identity:outcome:)`` keeps.
    private func releaseRunLockIfAtRest() {
        guard phase.isAtRest || phase == .removed, hold.isThisCopy else { return }
        setHold(.none)
    }

    /// Records what asking the bundle found about another copy's hold on it —
    /// only for a VM at rest holding no lock, the one case where a holder the
    /// bundle reports can only be another copy.
    func recordOtherCopyHold(heldElsewhere: Bool) {
        guard phase.isAtRest, !hold.isThisCopy else { return }
        setHold(heldElsewhere ? .anotherCopy : .none)
    }

    /// Catches a VM at rest up with what another copy of Kernova may have done
    /// while this copy held no lock: whether that copy holds the bundle now,
    /// the four state files it may have written, and where the VM rests.
    ///
    /// A VM holding the lock has nothing to catch up with — no other copy can
    /// have written its bundle — and one that is not at rest holds it.
    func refreshFromBundle() {
        guard phase.isAtRest, !hold.isThisCopy, let owner else { return }
        let bundle = owner.bundle
        recordOtherCopyHold(heldElsewhere: bundle.isRunLockedElsewhere())
        do {
            try bundle.refresh()
        } catch {
            #log(
                Self.logger, .warning,
                "Could not re-read the bundle of '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        let before = phase
        reconcileRest()
        guard phase != before else { return }
        #log(
            Self.logger, .notice,
            "Re-read '\(self.name, privacy: .public)' from its bundle: it now rests \(String(describing: self.phase), privacy: .public)"
        )
    }

    /// The one write of ``hold``, noticed by observers of
    /// ``heldByAnotherCopy`` — and logged — when it moves that, so a probe
    /// that finds what the last one found records nothing.
    private func setHold(_ new: consuming VMRunLockHold) {
        let wasHeldByAnotherCopy = hold.isAnotherCopy
        hold = new
        guard hold.isAnotherCopy != wasHeldByAnotherCopy else { return }
        if hold.isAnotherCopy {
            #log(
                Self.logger, .notice,
                "Found '\(self.name, privacy: .public)' held by another copy of Kernova")
        } else {
            #log(
                Self.logger, .notice,
                "Another copy of Kernova no longer holds '\(self.name, privacy: .public)'")
        }
        withMutation(keyPath: \.heldByAnotherCopy) {}
    }

    /// The reserve stage, between an operation's admission and its commit and
    /// in the same synchronous step: takes what `kind` claims beyond this VM —
    /// the accessory an attach passes through — so the next decision on any
    /// VM sees the claim. Throws, committing nothing, when the claim is held.
    private func reserve(for kind: VMOperationKind, on owner: VMInstance) throws {
        guard case .attachingUSB(let registryID) = kind else { return }
        guard let accessoryHolders else { throw VMAdmissionRefusal(refusal: .unsupportedByBuild) }
        try accessoryHolders.reserve(registryID, for: owner, AccessoryHoldersKey())
    }

    /// The admission commit: the operation holds the VM from here until
    /// ``finish(_:outcome:whenEnded:)``, and resolves `outcome` there.
    private func commitOperation(
        _ kind: VMOperationKind, outcome: VMOutcome, stopping stop: VMOutcome? = nil
    ) {
        let sessionState: VMOperationSessionState =
            switch phase {
            case .running(let id): .live(VMOperationSession(id: id, guest: .running, stopping: stop))
            case .livePaused(let id): .live(VMOperationSession(id: id, guest: .paused, stopping: stop))
            default: .none
            }
        setPhase(
            .operating(
                VMOperation(
                    kind: kind, startedFrom: phase, sessionState: sessionState, outcome: outcome)))
        #if DEBUG
        runningBody = outcome
        #endif
    }

    /// The operation holding the VM, which ends here, when `outcome` is its
    /// own.
    private func endingOperation(_ outcome: VMOutcome) -> VMOperation? {
        #if DEBUG
        runningBody = nil
        #endif
        guard case .operating(let operation) = phase, operation.outcome === outcome else {
            #log(
                Self.logger, .fault,
                "Operation on '\(self.name, privacy: .public)' ended while the VM was \(self.status.rawValue, privacy: .public)"
            )
            assertionFailure("An operation ended without holding its VM")
            return nil
        }
        return operation
    }

    /// The one ending commit — the only place a VM leaves an operation for a
    /// settled phase.
    ///
    /// Resolves the outcome for every joined caller, then ends in
    /// ``settled(poweredOff:)``. An operation that ends on a session a Force
    /// Stop is terminating hands the VM to ``VMOperationKind/forceStopping``
    /// instead, which rests it once that session ends — and the follow-ups
    /// `whenEnded` answers wait for that.
    private func finish<T>(
        _ ending: VMOperationEnding<T>, outcome: VMOutcome, whenEnded: WhenEnded? = nil
    ) -> Result<T, any Error> {
        guard let operation = endingOperation(outcome) else {
            return .failure(VMAdmissionRefusal(refusal: .invalidState))
        }
        // An accessory the operation reserved and never passed through is
        // free again the moment the operation lets go of the VM.
        if let owner { accessoryHolders?.releaseReservations(of: owner, AccessoryHoldersKey()) }
        let result: Result<T, any Error>
        let rest: VMOperationRest
        switch ending {
        case .rest(let target, let value):
            rest = target
            result = .success(value)
        case .failed(let target, let error):
            rest = target
            result = .failure(error)
        }
        let resting = resolve(rest, for: operation)
        if let session = operation.session, let stop = session.stopping {
            setPhase(
                .operating(
                    VMOperation(
                        kind: .forceStopping, startedFrom: resting, sessionState: .live(session),
                        outcome: stop)))
            #if DEBUG
            runningBody = stop
            #endif
            enqueue(whenEnded?(result.map { _ in () }) ?? [])
            outcome.resolve(result.map { _ in () })
            return result
        }
        // A bring-up that failed before it bound a session still holds the
        // context it opened, with that context's pipes and security scopes.
        if !resting.isSettledLive, sessionContext != nil { releaseSession() }
        setPhase(resting)
        if case .running = resting { owner?.operationDidSettleRunning(operation.kind) }
        enqueue(whenEnded?(result.map { _ in () }) ?? [])
        outcome.resolve(result.map { _ in () })
        settled(poweredOff: operation.sessionEnd == .poweredOff || rest == .poweredOff)
        return result
    }

    /// The tail of every step that settles the VM — out of an operation or a
    /// session, or into removal: fires ``onPoweredOff`` when the guest powered
    /// off, queues what the sessions that ended owe
    /// (``follow(_:whenSessionEnds:)``), drains the follow-ups, then lets go
    /// of the run lock unless the VM no longer rests — so an operation the
    /// drain admitted, the Ephemeral revert among them, runs under the lock
    /// the ending held.
    private func settled(poweredOff: Bool) {
        if poweredOff {
            owner?.guestDidPowerOff()
            enqueue(onPoweredOff?() ?? [])
        }
        enqueue(takeSessionEndFollowUps())
        drain()
        releaseRunLockIfAtRest()
    }

    /// The settled phase `rest` names for `operation`.
    private func resolve(_ rest: VMOperationRest, for operation: VMOperation) -> VMLifecyclePhase {
        switch rest {
        case .live(let guest):
            guard let session = operation.session else { return restAfterSessionEnd(of: operation) }
            switch guest {
            case .running: return .running(sessionID: session.id)
            case .paused: return .livePaused(sessionID: session.id)
            }
        case .atRest(let fallback):
            return restingPhase(withoutSlot: fallback)
        case .asStarted:
            switch operation.startedFrom {
            case .running: return resolve(.live(.running), for: operation)
            case .livePaused: return resolve(.live(.paused), for: operation)
            case .initialBoot: return restingPhase(withoutSlot: .initialBoot)
            case .failed(let message): return restingPhase(withoutSlot: .failed(message: message))
            case .stopped, .suspended, .operating, .removed: return restingPhase(withoutSlot: .stopped)
            }
        case .afterSessionEnd:
            return restAfterSessionEnd(of: operation)
        case .poweredOff:
            return restingPhase(withoutSlot: .stopped)
        }
    }

    /// Where `operation`'s session end rests the VM, read against the slot as
    /// the operation leaves it.
    private func restAfterSessionEnd(of operation: VMOperation) -> VMLifecyclePhase {
        restingPhase(withoutSlot: operation.sessionEnd?.rest ?? .stopped)
    }

    // MARK: - Session Actions

    /// Sends a graceful stop through `send` once one is admitted: a settled
    /// live VM, or an operation that tolerates it.
    ///
    /// Takes no admission and moves no phase — a guest may take minutes to go
    /// down, or never, and the session-ended event is what rests the VM.
    func requestStop(_ send: () async throws -> Void) async throws {
        try requireAdmitted(.sessionAction(.requestStop))
        try await send()
    }

    /// Force Stop: marks the live session *stopping* at admission — on a
    /// settled live VM by committing ``VMOperationKind/forceStopping``, during
    /// an operation that tolerates it on that operation's session — then
    /// delivers `terminate`'s completion as the session's end, to whichever
    /// phase holds the session by then. A second Force Stop joins the first.
    ///
    /// `terminate` is what stops the `VZVirtualMachine`. Returns once the
    /// session has ended; an operation that tolerated the stop keeps holding
    /// the VM until its body ends.
    func forceStop(_ terminate: () async throws -> Void) async throws {
        let stop = VMOutcome()
        let sessionID: UUID
        switch decide(.sessionAction(.forceStop), posture: .commit) {
        case .join(let outcome):
            return try await outcome.value()
        case .refuse(let reason):
            throw VMAdmissionRefusal(refusal: reason)
        case .admit:
            // Admitted only on a settled live VM, or on the live session of an
            // operation that tolerates the stop.
            switch phase {
            case .running(let id), .livePaused(let id):
                sessionID = id
                commitOperation(.forceStopping, outcome: stop, stopping: stop)
            case .operating(var operation):
                guard var session = operation.session else {
                    throw VMAdmissionRefusal(refusal: .invalidState)
                }
                sessionID = session.id
                session.stopping = stop
                operation.sessionState = .live(session)
                setPhase(.operating(operation))
            case .stopped, .initialBoot, .failed, .suspended, .removed:
                throw VMAdmissionRefusal(refusal: .invalidState)
            }
        }
        do {
            try await terminate()
        } catch {
            forceStopFailed(on: sessionID, error)
            stop.resolve(.failure(error))
            return try await stop.value()
        }
        sessionEnded(.poweredOff, from: sessionID)
        stop.resolve(.success(()))
        try await stop.value()
    }

    /// `terminate` threw: the session `sessionID` is live and no longer
    /// stopping. A ``VMOperationKind/forceStopping`` holding it ends back
    /// where it started, with the error.
    private func forceStopFailed(on sessionID: UUID, _ error: any Error) {
        guard case .operating(var operation) = phase, var session = operation.session,
            session.id == sessionID, session.stopping != nil
        else { return }
        session.stopping = nil
        operation.sessionState = .live(session)
        setPhase(.operating(operation))
        guard operation.kind == .forceStopping else { return }
        _ = finish(VMOperationEnding<Void>.failed(.asStarted, error), outcome: operation.outcome)
    }

    /// Cancels the operation of `family` holding the VM, whose own task
    /// unwinds it.
    func cancel(_ family: VMOperationKind.Family) throws {
        try requireAdmitted(.cancel(family))
        phase.operation?.outcome.task?.cancel()
    }

    /// Evicts a VM at rest from the library: it admits nothing afterwards.
    func remove() throws {
        try requireAdmitted(.evict)
        setPhase(.removed)
        settled(poweredOff: false)
    }

    /// Re-derives where a VM at rest rests from its bundle as it stands
    /// (``VMLifecyclePhase/atRest(for:layout:)``), keeping a failure's
    /// message.
    func reconcileRest() {
        guard phase.isAtRest, let owner else { return }
        if case .failed = phase { return }
        let derived = VMLifecyclePhase.atRest(for: owner.configuration, layout: owner.bundleLayout)
        guard derived != phase else { return }
        setPhase(derived)
    }

    #if DEBUG
    /// The outcome of the operation whose body is running, which no test may
    /// place a phase over.
    @ObservationIgnored private var runningBody: VMOutcome?

    /// Puts the VM straight into `phase`, bypassing every rule a transition
    /// obeys — the run lock's among them, which it neither takes nor releases;
    /// tests only, and the one way a test places a phase.
    ///
    /// Refused while an operation's body is running: only that body's ending
    /// may move the VM out of its operation, so a test awaits the outcome first.
    func placeForTesting(_ phase: VMLifecyclePhase) {
        precondition(
            runningBody == nil,
            "A phase placed over an operation's running body; await its outcome first")
        setPhase(phase)
        drain()
    }
    #endif

    /// The one write of ``phase`` after construction, so the edge onto an
    /// attachable session is noticed wherever the transition came from, and
    /// the follow-ups it owes queued for the step's drain.
    private func setPhase(_ new: VMLifecyclePhase) {
        let wasAttachable = attachableSessionID != nil
        phase = new
        phaseCommits &+= 1
        guard !wasAttachable, attachableSessionID != nil else { return }
        enqueue(onSessionBecameAttachable?() ?? [])
    }

    // MARK: - Session Events

    /// Builds the event sink a new session delivers into.
    ///
    /// Events hop to the main actor and apply only while the delivering
    /// session is still the one this instance holds.
    func makeSessionEvents() -> VMSessionEvents {
        VMSessionEvents { [weak self] sessionID, event in
            Task { @MainActor in
                self?.deliverSessionEvent(event, from: sessionID)
            }
        }
    }

    /// Applies `event` if `sessionID` still names the live session; drops it
    /// otherwise.
    func deliverSessionEvent(_ event: VMSessionEvent, from sessionID: UUID) {
        guard liveSessionID == sessionID else { return }
        handleSessionEvent(event)
    }

    func handleSessionEvent(_ event: VMSessionEvent) {
        switch event {
        case .guestDidStop:
            if let sessionID = liveSessionID { sessionEnded(.poweredOff, from: sessionID) }
            #log(Self.logger, .notice, "Guest stopped for VM '\(self.name, privacy: .public)'")
        case .didStopWithError(let error):
            if let sessionID = liveSessionID {
                sessionEnded(.stoppedWithError(message: error.localizedDescription), from: sessionID)
            }
            #log(
                Self.logger, .error,
                "VM '\(self.name, privacy: .public)' stopped with error: \(error.localizedDescription, privacy: .public)"
            )
        case .networkAttachmentDisconnected(let error):
            sessionContext?.networkAttachmentCoordinator?.attachmentWasDisconnected(error: error)
        case .usbPassthroughDeviceDidDisconnect(let deviceID):
            // VZ has already detached the device; only Kernova's record of it
            // is left to drop. An unplug is routine — a fast user switch
            // disconnects every assigned accessory too — so it never alerts.
            guard let gone = accessoryLeftGuest(deviceID: deviceID) else { break }
            #log(
                Self.logger, .notice,
                "USB accessory \(gone.accessory.displayName, privacy: .public) disconnected from VM '\(self.name, privacy: .public)'"
            )
        }
    }

    /// The one session-ended path: the session `sessionID` ended, whatever
    /// phase holds it. A settled VM rests; a
    /// ``VMOperationKind/forceStopping`` ends with it; any other operation
    /// keeps holding the VM and learns its session is gone. Dropped when no
    /// phase holds the session any longer.
    private func sessionEnded(_ end: VMSessionEnd, from sessionID: UUID) {
        switch phase {
        case .running(let id), .livePaused(let id):
            guard id == sessionID else { return }
            releaseSession()
            setPhase(restingPhase(withoutSlot: end.rest))
            settled(poweredOff: end == .poweredOff)
        case .operating(let operation):
            guard let ended = endOperationSession(sessionID, end) else { return }
            if operation.kind == .forceStopping {
                _ = finish(VMOperationEnding<Void>.rest(.afterSessionEnd, ()), outcome: operation.outcome)
            } else {
                ended.stopping?.resolve(.success(()))
            }
        case .stopped, .initialBoot, .failed, .suspended, .removed:
            return
        }
    }

    /// Marks the operation's session `sessionID` ended, keeping the operation,
    /// and answers the session as it stood — `nil` when the operation holds no
    /// such session.
    private func endOperationSession(
        _ sessionID: UUID, _ end: VMSessionEnd
    ) -> VMOperationSession? {
        guard case .operating(var operation) = phase, let session = operation.session,
            session.id == sessionID
        else { return nil }
        operation.sessionState = .ended(end)
        releaseSession()
        setPhase(.operating(operation))
        return session
    }

    /// Releases the session context, if one is open, every accessory the
    /// session held, and every follow-up scoped to it.
    private func releaseSession() {
        sessionContext?.tearDown()
        sessionContext = nil
        dropSessionFollowUps()
        guard let owner else { return }
        accessoryHolders?.releaseAll(of: owner, AccessoryHoldersKey())
        owner.sessionDidEnd()
    }

    // MARK: - USB Accessories

    /// The library's record of which VM holds each accessory; `nil` for a VM
    /// no library holds, which holds none.
    private var accessoryHolders: VMAccessoryHolders? { owner?.peers?.accessoryHolders }

    /// Drops the attachment `deviceID` names from what this VM's guest holds,
    /// answering it — an unplug VZ reported, or one the host's own evidence
    /// shows. `nil` when the guest held no such attachment.
    @discardableResult
    func accessoryLeftGuest(deviceID: UUID) -> AttachedUSBAccessory? {
        guard let owner else { return nil }
        return accessoryHolders?.release(deviceID: deviceID, of: owner, AccessoryHoldersKey())
    }

    // MARK: - Session Lifecycle

    // periphery:ignore:parameters bringUp - an access token: its type admits the caller
    /// Installs the context `make` opens as the session context of the
    /// bring-up holding the VM, ending whatever attempt that bring-up had open
    /// first — so an attempt's pipes and security scopes are always released
    /// before the next attempt's are taken.
    @discardableResult
    func beginSessionContext(
        _ bringUp: borrowing VMBringUpContext, _ make: () -> VMSessionContext
    ) -> VMSessionContext {
        endOperationSessionItself()
        let context = make()
        sessionContext = context
        return context
    }

    #if DEBUG
    /// Installs the context `make` opens with no bring-up behind it, releasing
    /// any prior one; tests only.
    @discardableResult
    func installSessionContextForTesting(_ make: () -> VMSessionContext) -> VMSessionContext {
        sessionContext?.tearDown()
        let context = make()
        sessionContext = context
        return context
    }
    #endif

    // periphery:ignore:parameters bringUp - an access token: its type admits the caller
    /// Takes the pipes, cold-attached removable media and directory share a
    /// configuration build produced into the bring-up's open session context.
    func adoptBuildResult(
        _ bringUp: borrowing VMBringUpContext, _ result: ConfigurationBuilder.BuildResult
    ) {
        guard let sessionContext else {
            #log(
                Self.logger, .fault,
                "No session context to adopt a build result for '\(self.name, privacy: .public)'")
            assertionFailure("adoptBuildResult without beginSessionContext for '\(name)'")
            return
        }
        sessionContext.serialInputPipe = result.serialInputPipe
        sessionContext.serialOutputPipe = result.serialOutputPipe
        sessionContext.clipboardInputPipe = result.clipboardInputPipe
        sessionContext.clipboardOutputPipe = result.clipboardOutputPipe
        sessionContext.liveRemovableMedia = result.coldRemovableMedia
        sessionContext.directoryShare = result.directoryShare
        sessionContext.vmnetNetworks = result.vmnetNetworks
    }

    /// Creates the VM on its own queue, stores the session, and binds it to the
    /// bring-up that holds the VM, answering the session and the context that
    /// now holds it.
    ///
    /// `nil` when no session context is open — a programming error, since every
    /// bring-up opens one before building the configuration this takes. The
    /// just-created `VZVirtualMachine` is released rather than handed back: a
    /// session this instance does not hold is one nothing can stop.
    func beginSession(
        _ context: borrowing VMBringUpContext, from result: ConfigurationBuilder.BuildResult
    ) async -> (session: VMSession, context: VMSessionContext)? {
        // The configuration was assembled off-main and is handed over whole:
        // nothing touches it after the VM is created from it.
        nonisolated(unsafe) let vzConfig = result.configuration
        let session = await VMSession.make(configuration: vzConfig, events: makeSessionEvents())
        guard let sessionContext, case .operating(var operation) = phase,
            operation.kind == context.operation.kind
        else {
            #log(
                Self.logger, .fault,
                "No bring-up and session context to attach a session to for '\(self.name, privacy: .public)'"
            )
            assertionFailure("beginSession outside the bring-up that holds '\(name)'")
            return nil
        }
        sessionContext.session = session
        operation.sessionState = .live(VMOperationSession(id: session.id, guest: .running))
        setPhase(.operating(operation))
        return (session, sessionContext)
    }

    #if DEBUG
    /// Binds a session identity with no `VZVirtualMachine` behind it to the
    /// bring-up holding the VM — what ``VMBringUpContext/bindSessionForTesting(_:)``
    /// does.
    fileprivate func bindSession(withoutMachine sessionID: UUID) {
        guard case .operating(var operation) = phase else { return }
        operation.sessionState = .live(VMOperationSession(id: sessionID, guest: .running))
        setPhase(.operating(operation))
    }
    #endif

    // MARK: - Context Reads

    fileprivate var operationSessionID: UUID? { phase.operation?.session?.id }

    fileprivate var operationSessionEnd: VMSessionEnd? { phase.operation?.sessionEnd }

    /// Ends the operation's session, or — before a bring-up bound one —
    /// releases the context it opened.
    fileprivate func endOperationSessionItself() {
        if let sessionID = operationSessionID {
            endOperationSession(sessionID, .endedByOperation)?.stopping?.resolve(.success(()))
        } else if sessionContext != nil {
            releaseSession()
        }
    }
}

// MARK: - Run Lock

/// Whose copy of Kernova holds a VM's bundle run lock, as that VM's
/// ``VMActivity`` last learned it.
enum VMRunLockHold: ~Copyable {
    /// No copy, as far as this one knows.
    case none
    /// This copy, holding the lock itself.
    case thisCopy(VMBundleRunLock)
    /// Another copy, as this copy's last lock attempt or probe found.
    case anotherCopy

    var isThisCopy: Bool {
        switch self {
        case .thisCopy: true
        case .none: false
        case .anotherCopy: false
        }
    }

    var isAnotherCopy: Bool {
        switch self {
        case .anotherCopy: true
        case .none: false
        case .thisCopy: false
        }
    }
}

// MARK: - Contexts

/// The authority an operation's body acts with, minted only by ``VMActivity``
/// for the operation holding the VM.
///
/// Non-copyable and passed borrowed, so it cannot be stored, captured by a
/// task, or used after its operation ended.
struct VMOperationContext: ~Copyable, Sendable {
    private let activity: VMActivity
    let kind: VMOperationKind

    /// The machine-file operations on the bundle of the VM this operation
    /// holds — the only way to reach them.
    let bundle: VMBundle.MachineFiles

    /// The permit the operation's own writes to the VM's state files act
    /// with.
    let permit: VMEditPermit

    /// What ``VMBundle/MachineFiles/init(of:_:)`` asks for, so only a context
    /// can reach a VM's machine files: the initializer is `fileprivate`, which
    /// `@testable import` does not open.
    struct MachineFilesKey {
        fileprivate init() {}
    }

    @MainActor
    fileprivate init(activity: VMActivity, kind: VMOperationKind, owner: VMInstance) {
        self.activity = activity
        self.kind = kind
        self.bundle = VMBundle.MachineFiles(of: owner, MachineFilesKey())
        self.permit = VMEditPermit(instance: owner, authority: .operation(kind))
    }

    /// The VM this operation holds.
    var instance: VMInstance { permit.instance }

    /// The operation's live session, or `nil` once it ended or before a
    /// bring-up created one.
    @MainActor var session: VMSession? {
        activity.operationSessionID == nil ? nil : activity.session
    }

    /// The identity of the operation's live session, or `nil`.
    @MainActor var sessionID: UUID? { activity.operationSessionID }

    /// How the operation's session ended, once it has.
    @MainActor var sessionEnd: VMSessionEnd? { activity.operationSessionEnd }

    /// Ends the operation's session itself — a save, a revert, a retried boot
    /// attempt — keeping the operation; before a bring-up has bound a session,
    /// releases the context it opened.
    @MainActor func endSession() {
        activity.endOperationSessionItself()
    }

    /// Drops the attachment `deviceID` names from what this VM's guest
    /// holds, answering it — `nil` when the guest held no such attachment.
    @MainActor @discardableResult
    func releaseAccessory(deviceID: UUID) -> AttachedUSBAccessory? {
        activity.accessoryLeftGuest(deviceID: deviceID)
    }
}

/// The authority an accessory attach's body acts with: an operation admitted
/// to attach `reservation`'s accessory, whose admission reserved it — minted
/// only by ``VMActivity/attachUSBAccessory(_:_:)``.
struct VMUSBAttachContext: ~Copyable, Sendable {
    let operation: VMOperationContext
    let reservation: VMAccessoryReservation

    fileprivate init(
        operation: consuming VMOperationContext, reservation: consuming VMAccessoryReservation
    ) {
        self.operation = operation
        self.reservation = reservation
    }
}

/// One accessory reserved for one VM in the library's
/// ``VMAccessoryHolders`` — what ``USBAccessoryProviding/attach(_:)`` takes,
/// so no accessory is passed through to a guest unless it is reserved for
/// that guest's VM.
///
/// Minted only once the reservation is written — by an attach's admission,
/// or by ``VMBringUpContext/reserveAccessory(_:)``. Non-copyable and passed
/// borrowed, so it cannot outlive the operation that reserved it.
struct VMAccessoryReservation: ~Copyable, Sendable {
    let registryID: UInt64
    /// The VM the accessory is reserved for.
    let instance: VMInstance

    fileprivate init(registryID: UInt64, instance: VMInstance) {
        self.registryID = registryID
        self.instance = instance
    }

    /// Records `attached` as the guest's, answering whether the reservation
    /// still stood — `false` once the VM's session ended under the attach,
    /// which released it.
    @MainActor func hold(_ attached: AttachedUSBAccessory) -> Bool {
        instance.peers?.accessoryHolders.settle(
            registryID, as: attached, for: instance, AccessoryHoldersKey()) ?? false
    }
}

/// What every write to ``VMAccessoryHolders`` asks for, so only this file —
/// ``VMActivity``'s admission, operation endings, session teardown and
/// unplugs, a restore's bring-up, and the reservations it mints — writes the
/// holder map. The initializer is `fileprivate`, which `@testable import`
/// does not open.
struct AccessoryHoldersKey {
    fileprivate init() {}
}

/// The authority a bring-up's body acts with — the only one
/// ``VMActivity/beginSessionContext(_:_:)``, ``VMActivity/adoptBuildResult(_:_:)``
/// and ``VMActivity/beginSession(_:from:)`` take, so only a bring-up, admitted
/// past the identity check, can open and fill a session.
struct VMBringUpContext: ~Copyable, Sendable {
    let operation: VMOperationContext

    fileprivate init(operation: consuming VMOperationContext) {
        self.operation = operation
    }

    /// Reserves the accessory `registryID` names for the VM this bring-up
    /// holds, for a restore to put back in the configuration it builds —
    /// `nil`, reserving nothing, while any VM holds it.
    @MainActor func reserveAccessory(_ registryID: UInt64) -> VMAccessoryReservation? {
        let instance = operation.instance
        guard let holders = instance.peers?.accessoryHolders,
            (try? holders.reserve(registryID, for: instance, AccessoryHoldersKey())) != nil
        else { return nil }
        return VMAccessoryReservation(registryID: registryID, instance: instance)
    }

    /// Records `restoration`'s accessory as the guest's once the machine
    /// configured with it exists, answering whether this VM still held the
    /// reservation ``reserveAccessory(_:)`` made.
    @MainActor func hold(_ restoration: USBPassthroughRestoration) -> Bool {
        let instance = operation.instance
        return instance.peers?.accessoryHolders.settle(
            restoration.registryID, as: restoration.attached, for: instance,
            AccessoryHoldersKey()) ?? false
    }

    #if DEBUG
    /// Binds a session identity with no `VZVirtualMachine` behind it; tests
    /// only.
    @MainActor func bindSessionForTesting(_ sessionID: UUID) {
        operation.activityForTesting.bindSession(withoutMachine: sessionID)
    }
    #endif
}

/// The authority a guest start's body acts with: a bring-up admitted as
/// `kind`, minted only by ``VMActivity/launchStartGuest(_:identity:resolving:_:)``.
struct VMGuestStartContext: ~Copyable, Sendable {
    let bringUp: VMBringUpContext
    let kind: VMGuestStartKind

    fileprivate init(bringUp: consuming VMBringUpContext, kind: VMGuestStartKind) {
        self.bringUp = bringUp
        self.kind = kind
    }
}

/// The authority a capture's body acts with: a snapshot capture or a clone's
/// copy admitted in `mode`, minted only by ``VMActivity/captureSnapshot(_:_:)``
/// and ``VMActivity/launchCopyOut(_:_:)``.
struct VMCaptureContext: ~Copyable, Sendable {
    let operation: VMOperationContext
    let mode: VMCaptureMode

    fileprivate init(operation: consuming VMOperationContext, mode: VMCaptureMode) {
        self.operation = operation
        self.mode = mode
    }
}

/// The authority a revert's body acts with: a bring-up admitted to revert to
/// `snapshot`, minted only by ``VMActivity/launchRevert(to:resumesAfter:origin:identity:resolving:_:)``.
struct VMRevertContext: ~Copyable, Sendable {
    let bringUp: VMBringUpContext
    let snapshot: VMSnapshot
    /// Whether the revert brings the guest back up on the snapshot's saved
    /// state once the files are in place.
    let resumesAfter: Bool

    fileprivate init(bringUp: consuming VMBringUpContext, snapshot: VMSnapshot, resumesAfter: Bool) {
        self.bringUp = bringUp
        self.snapshot = snapshot
        self.resumesAfter = resumesAfter
    }
}

/// The authority one write to a VM's state files acts with, minted only by
/// admission: by ``VMActivity/edit(_:_:)`` for the edit classes it admitted,
/// and on every ``VMOperationContext`` for the operation's own writes.
///
/// Non-copyable and passed borrowed, so it cannot be stored or outlive the
/// admission that minted it.
struct VMEditPermit: ~Copyable, Sendable {
    /// What admission minted a permit for.
    enum Authority: Sendable, Equatable {
        /// An edit admitted for these classes beside whatever holds the VM.
        case edit(VMEditClasses)
        /// The operation holding the VM, whose admission covers its own
        /// writes whole: while it holds the VM, nothing else is admitted but
        /// the edits its kind declares.
        case operation(VMOperationKind)

        /// Whether this authority may write a field any one of `classes`
        /// writes (``VMStateFieldClasses``).
        func mayWrite(_ classes: VMEditClasses) -> Bool {
            switch self {
            case .edit(let admitted): !admitted.isDisjoint(with: classes)
            case .operation: true
            }
        }
    }

    /// The VM this permit writes.
    let instance: VMInstance
    let authority: Authority

    /// The commits to that VM's state files — the only way to reach them.
    let bundle: VMBundle.StateFiles

    /// What ``VMBundle/StateFiles/init(of:_:)`` asks for, so only a permit can
    /// reach a VM's state files: the initializer is `fileprivate`, which
    /// `@testable import` does not open.
    struct StateFilesKey {
        fileprivate init() {}
    }

    @MainActor
    fileprivate init(instance: VMInstance, authority: Authority) {
        self.instance = instance
        self.authority = authority
        self.bundle = VMBundle.StateFiles(of: instance, authority: authority, StateFilesKey())
    }

    /// Writes the VM's configuration through the library it belongs to
    /// (``VMInstance/onUpdateConfiguration``); a VM no library has wired
    /// changes nothing and is refused as
    /// ``VMLibrary/SettingsRefusal/noLibrary``.
    @MainActor @discardableResult
    func updateConfiguration(_ mutate: (inout VMConfiguration) -> Void) -> VMLibrary.SettingsWrite {
        instance.onUpdateConfiguration?(self, mutate) ?? .refused(.noLibrary)
    }

    /// ``updateConfiguration(_:)`` for both halves of the settings
    /// (``VMInstance/onUpdateSettings``).
    @MainActor @discardableResult
    func updateSettings(
        configuration: (inout VMConfiguration) -> Void, hostState: (inout VMHostState) -> Void
    ) -> VMLibrary.SettingsWrite {
        instance.onUpdateSettings?(self, configuration, hostState) ?? .refused(.noLibrary)
    }
}

#if DEBUG
extension VMOperationContext {
    fileprivate var activityForTesting: VMActivity { activity }
}
#endif

/// Where an operation leaves the VM — a live phase or an at-rest one, never
/// another operation or removal.
enum VMOperationRest: Sendable, Equatable {
    /// Live with the operation's session — or, once that session ended, where
    /// its end rests the VM.
    case live(VMGuestRunState)
    /// At rest: suspended while the slot is on disk, this phase otherwise.
    case atRest(VMRestPhase)
    /// Back where the operation started.
    case asStarted
    /// Where the operation's session ending rests the VM.
    case afterSessionEnd
    /// Powered off: stopped, or suspended on a slot that survived, with
    /// ``VMActivity/onPoweredOff`` fired after the commit.
    case poweredOff
}

/// How an operation's body ended. Only ``VMActivity/delete(_:)`` removes a
/// VM.
enum VMOperationEnding<T> {
    case rest(VMOperationRest, T)
    case failed(VMOperationRest, any Error)
}

extension VMOperationKind {
    /// Where a body that threw leaves the VM.
    func restAfterFailure(_ error: any Error) -> VMOperationRest {
        let transient = VirtualizationService.isTransientStartError(error)
        switch self {
        case .bringUp(.guestStart):
            return .atRest(transient ? .stopped : .failed(message: error.localizedDescription))
        case .bringUp(.settingUp):
            if error is CancellationError || transient { return .atRest(.initialBoot) }
            return .atRest(.failed(message: error.localizedDescription))
        case .bringUp(.reverting):
            return .atRest(.stopped)
        case .saving:
            return .atRest(.failed(message: error.localizedDescription))
        case .pausing, .resuming, .capturingSnapshot, .deletingSnapshot, .attachingUSB,
            .detachingUSB, .reconcilingMedia, .forceStopping, .discardingSavedState, .deleting,
            .creatingStorageDisk, .removingStorageDisk, .creatingRemovableMedia, .copyingOut:
            return .asStarted
        }
    }
}
