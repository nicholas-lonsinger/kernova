import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// What a VM's ``VMActivity`` reads from, and tells, the VM it belongs to.
@MainActor
protocol VMActivityOwner: AnyObject {
    /// The name the activity's log lines identify the VM by.
    var name: String { get }

    /// Whether the bundle holds a suspend slot — what
    /// ``VMActivity/restingPhase(withoutSlot:)`` reads.
    var hasSaveFile: Bool { get }

    /// The bundle an operation's context runs machine-file work on.
    var bundle: VMBundle { get }

    /// The VM's own facts and the library's that admission reads, without the
    /// identity term.
    var admissionFacts: VMAdmission.Facts { get }

    /// The live VM whose identity bringing this one up by `kind` would
    /// duplicate, or `nil` when nothing collides.
    func identityConflict(for kind: VMBringUpKind) -> VMIdentityConflict?

    /// Called once the session is released.
    func sessionDidEnd()

    /// Called once a power-off has rested the VM, before
    /// ``VMActivity/onPoweredOff`` fires.
    func guestDidPowerOff()

    /// Called once an operation of `kind` has ended with the guest running.
    func operationDidSettleRunning(_ kind: VMOperationKind)
}

/// Where a VM is in its lifecycle, the live session it holds, and the one
/// place any request on it is admitted and committed.
///
/// The only writer of ``phase`` and ``sessionContext``. The phase moves only at
/// an operation's admission commit, at its ending, at a Force Stop's admission
/// and its completion, and on a session event; each of those is one
/// synchronous step, so no decision can read a phase another request is about
/// to replace.
@MainActor
@Observable
final class VMActivity {
    /// The VM this activity belongs to.
    ///
    /// Set by the owner as it is created.
    @ObservationIgnored weak var owner: (any VMActivityOwner)?

    private(set) var phase: VMLifecyclePhase

    /// Everything scoped to the current `VZVirtualMachine`'s lifetime, bound to
    /// the session ``VMLifecyclePhase/sessionID`` names.
    private(set) var sessionContext: VMSessionContext?

    /// The live VM's isolation domain — the only type that calls into the
    /// `VZVirtualMachine` and its device objects.
    var session: VMSession? { sessionContext?.session }

    var status: VMStatus { phase.status }

    var errorMessage: String? { phase.errorMessage }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMActivity")

    init(phase: VMLifecyclePhase) {
        self.phase = phase
    }

    private var name: String { owner?.name ?? "" }

    // MARK: - Hooks

    /// Fired when a power-off has rested the VM — immediately for a settled
    /// VM, and at the ending of the operation that held it otherwise — so a
    /// request it makes is decided against the phase the VM rests at.
    ///
    /// Wired by `VMLibrary.wireHooks(for:)`, whose handler reverts an
    /// Ephemeral Mode VM to its baseline here.
    @ObservationIgnored var onPoweredOff: (@MainActor () -> Void)?

    /// Fired on the edge where this VM becomes something a device can be
    /// attached to — ``attachableSessionID`` going from `nil` to naming a
    /// session — so it fires once per session.
    ///
    /// Wired by `VMLibrary.wireHooks(for:)`.
    @ObservationIgnored var onSessionBecameAttachable: (@MainActor () -> Void)?

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

    var isColdPaused: Bool { phase.presented == .suspended }

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
    func decide(
        _ request: VMAdmission.Request, posture: VMAdmission.Posture
    ) -> VMAdmission.Decision {
        guard let owner else { return .refuse(.invalidState) }
        var facts = owner.admissionFacts
        if posture == .commit,
            let kind = VMAdmission.bringUpKind(for: request, phase: phase, facts: facts),
            kind.checksIdentity
        {
            facts.identityConflict = owner.identityConflict(for: kind)
        }
        return VMAdmission.decide(request, posture: posture, phase: phase, facts: facts)
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
    /// bundle of the VM it was admitted on.
    @discardableResult
    private func requireAdmitted(_ request: VMAdmission.Request) throws -> VMBundle {
        guard let owner else { throw refusal(.invalidState, for: request) }
        switch decide(request, posture: .commit) {
        case .admit:
            return owner.bundle
        case .join:
            throw refusal(phase.operation.map { .busy($0.kind) } ?? .invalidState, for: request)
        case .refuse(let reason):
            throw refusal(reason, for: request)
        }
    }

    private func refusal(
        _ reason: VMAdmission.Refusal, for request: VMAdmission.Request
    ) -> VMAdmissionRefusal {
        #log(
            Self.logger, .notice,
            "Refused \(String(describing: request), privacy: .public) for '\(self.name, privacy: .public)': \(String(describing: reason), privacy: .public)"
        )
        return VMAdmissionRefusal(refusal: reason)
    }

    // MARK: - Operations

    /// Admits `kind`, commits it, runs `body` under its context, and commits
    /// where the body leaves the VM — the whole of one operation.
    ///
    /// A body that throws rests the VM where its kind's
    /// ``VMOperationKind/restAfterFailure(_:)`` says.
    func perform<T>(
        _ kind: VMOperationKind,
        _ body: (borrowing VMOperationContext) async throws -> VMOperationEnding<T>
    ) async throws -> T {
        let bundle = try requireAdmitted(.operation(kind))
        let outcome = commitOperation(kind)
        let context = VMOperationContext(activity: self, kind: kind, bundle: bundle)
        let ending: VMOperationEnding<T>
        do {
            ending = try await body(context)
        } catch {
            ending = .failed(kind.restAfterFailure(error), error)
        }
        return try finish(ending, outcome: outcome).get()
    }

    /// ``perform(_:_:)`` for a bring-up, whose body alone may create a session.
    func bringUp<T>(
        _ kind: VMBringUpKind,
        _ body: (borrowing VMBringUpContext) async throws -> VMOperationEnding<T>
    ) async throws -> T {
        let operationKind = VMOperationKind.bringUp(kind)
        let bundle = try requireAdmitted(.operation(operationKind))
        let outcome = commitOperation(operationKind)
        let context = VMBringUpContext(
            operation: VMOperationContext(activity: self, kind: operationKind, bundle: bundle))
        let ending: VMOperationEnding<T>
        do {
            ending = try await body(context)
        } catch {
            ending = .failed(operationKind.restAfterFailure(error), error)
        }
        return try finish(ending, outcome: outcome).get()
    }

    /// ``perform(_:_:)`` for an operation no caller waits on: admitted and
    /// committed before this returns, its body run in a task the operation
    /// owns, and its end reported through the outcome.
    ///
    /// `whenEnded` runs at the ending commit, after the VM rests and before the
    /// outcome resolves — so it reads the phase the operation left, and whoever
    /// awaits the outcome finds its work done.
    @discardableResult
    func launch(
        _ kind: VMOperationKind,
        whenEnded: (@MainActor (Result<Void, any Error>) -> Void)? = nil,
        _ body: @escaping @MainActor (borrowing VMOperationContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        let bundle = try requireAdmitted(.operation(kind))
        let outcome = commitOperation(kind)
        outcome.task = Task { @MainActor in
            let context = VMOperationContext(activity: self, kind: kind, bundle: bundle)
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

    /// ``launch(_:whenEnded:_:)`` for a bring-up — a guest setup, or a revert
    /// no caller waits on.
    @discardableResult
    func launchBringUp(
        _ kind: VMBringUpKind,
        whenEnded: (@MainActor (Result<Void, any Error>) -> Void)? = nil,
        _ body: @escaping @MainActor (borrowing VMBringUpContext) async throws -> VMOperationEnding<Void>
    ) throws -> VMOutcome {
        let operationKind = VMOperationKind.bringUp(kind)
        let bundle = try requireAdmitted(.operation(operationKind))
        let outcome = commitOperation(operationKind)
        outcome.task = Task { @MainActor in
            let context = VMBringUpContext(
                operation: VMOperationContext(activity: self, kind: operationKind, bundle: bundle))
            let ending: VMOperationEnding<Void>
            do {
                ending = try await body(context)
            } catch {
                ending = .failed(operationKind.restAfterFailure(error), error)
            }
            _ = self.finish(ending, outcome: outcome, whenEnded: whenEnded)
        }
        return outcome
    }

    /// ``perform(_:_:)`` for an operation with nothing to await.
    func performNow<T>(
        _ kind: VMOperationKind,
        _ body: (borrowing VMOperationContext) throws -> VMOperationEnding<T>
    ) throws -> T {
        let bundle = try requireAdmitted(.operation(kind))
        let outcome = commitOperation(kind)
        let context = VMOperationContext(activity: self, kind: kind, bundle: bundle)
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
    /// that removes a VM.
    ///
    /// A body that throws rests the VM where the kind's
    /// ``VMOperationKind/restAfterFailure(_:)`` says.
    func delete(_ body: (borrowing VMOperationContext) async throws -> Void) async throws {
        let bundle = try requireAdmitted(.operation(.deleting))
        let outcome = commitOperation(.deleting)
        let context = VMOperationContext(activity: self, kind: .deleting, bundle: bundle)
        do {
            try await body(context)
        } catch {
            let ending = VMOperationEnding<Void>.failed(
                VMOperationKind.deleting.restAfterFailure(error), error)
            return try finish(ending, outcome: outcome).get()
        }
        guard endingOperation(outcome) != nil else { return }
        if sessionContext != nil { releaseSession() }
        setPhase(.removed)
        outcome.resolve(.success(()))
    }

    /// The admission commit: the operation holds the VM from here until
    /// ``finish(_:outcome:whenEnded:)``.
    @discardableResult
    private func commitOperation(
        _ kind: VMOperationKind, outcome: VMOutcome = VMOutcome(),
        stopping stop: VMOutcome? = nil
    ) -> VMOutcome {
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
        return outcome
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
    /// Resolves the outcome for every joined caller, and fires ``onPoweredOff``
    /// after the rest commit when the operation's guest powered off. An
    /// operation that ends on a session a Force Stop is terminating hands the
    /// VM to ``VMOperationKind/forceStopping`` instead, which rests it once
    /// that session ends.
    private func finish<T>(
        _ ending: VMOperationEnding<T>, outcome: VMOutcome,
        whenEnded: (@MainActor (Result<Void, any Error>) -> Void)? = nil
    ) -> Result<T, any Error> {
        guard let operation = endingOperation(outcome) else {
            return .failure(VMAdmissionRefusal(refusal: .invalidState))
        }
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
            whenEnded?(result.map { _ in () })
            outcome.resolve(result.map { _ in () })
            return result
        }
        // A bring-up that failed before it bound a session still holds the
        // context it opened, with that context's pipes and security scopes.
        if !resting.isSettledLive, sessionContext != nil { releaseSession() }
        setPhase(resting)
        if case .running = resting { owner?.operationDidSettleRunning(operation.kind) }
        whenEnded?(result.map { _ in () })
        outcome.resolve(result.map { _ in () })
        if operation.sessionEnd == .poweredOff || rest == .poweredOff {
            owner?.guestDidPowerOff()
            onPoweredOff?()
        }
        return result
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
            throw refusal(reason, for: .sessionAction(.forceStop))
        case .admit:
            // Admitted only on a settled live VM, or on the live session of an
            // operation that tolerates the stop.
            switch phase {
            case .running(let id), .livePaused(let id):
                sessionID = id
                commitOperation(.forceStopping, outcome: stop, stopping: stop)
            case .operating(var operation):
                guard var session = operation.session else {
                    throw refusal(.invalidState, for: .sessionAction(.forceStop))
                }
                sessionID = session.id
                session.stopping = stop
                operation.sessionState = .live(session)
                setPhase(.operating(operation))
            case .stopped, .initialBoot, .failed, .suspended, .removed:
                throw refusal(.invalidState, for: .sessionAction(.forceStop))
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
    }

    /// Rests a suspended VM whose slot is gone at `.stopped`.
    func reconcileRest() {
        guard phase == .suspended, owner?.hasSaveFile == false else { return }
        setPhase(.stopped)
    }

    #if DEBUG
    /// The outcome of the operation whose body is running, which no test may
    /// place a phase over.
    @ObservationIgnored private var runningBody: VMOutcome?

    /// Puts the VM straight into `phase`, bypassing every rule a transition
    /// obeys; tests only, and the one way a test places a phase.
    ///
    /// Refused while an operation's body is running: only that body's ending
    /// may move the VM out of its operation, so a test awaits the outcome first.
    func placeForTesting(_ phase: VMLifecyclePhase) {
        precondition(
            runningBody == nil,
            "A phase placed over an operation's running body; await its outcome first")
        setPhase(phase)
    }
    #endif

    /// The one write of ``phase`` after construction, so the edge onto an
    /// attachable session is noticed wherever the transition came from.
    private func setPhase(_ new: VMLifecyclePhase) {
        let wasAttachable = attachableSessionID != nil
        phase = new
        guard !wasAttachable, attachableSessionID != nil else { return }
        onSessionBecameAttachable?()
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
            guard let context = sessionContext,
                let gone = context.liveUSBAccessories.first(where: { $0.deviceID == deviceID })
            else { break }
            context.liveUSBAccessories.removeAll { $0.deviceID == deviceID }
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
            if end == .poweredOff {
                owner?.guestDidPowerOff()
                onPoweredOff?()
            }
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

    /// Releases the session context, if one is open.
    private func releaseSession() {
        sessionContext?.tearDown()
        sessionContext = nil
        owner?.sessionDidEnd()
    }

    // MARK: - Session Lifecycle

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

    /// Takes the pipes and cold-attached removable media a configuration build
    /// produced into the bring-up's open session context.
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

    /// What ``VMBundle/machineFiles(_:)`` asks for, so only a context can
    /// reach a bundle's machine files: the initializer is `fileprivate`, which
    /// `@testable import` does not open.
    struct MachineFilesKey {
        fileprivate init() {}
    }

    @MainActor
    fileprivate init(activity: VMActivity, kind: VMOperationKind, bundle: VMBundle) {
        self.activity = activity
        self.kind = kind
        self.bundle = bundle.machineFiles(MachineFilesKey())
    }

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

    /// Waits for the operation's session to end, and answers how.
    ///
    /// - Throws: `CancellationError` once the operation's task is cancelled.
    @MainActor func sessionEnded() async throws -> VMSessionEnd {
        let activity = activity
        try await waitForObservedChangeUnlessCancelled { activity.operationSessionEnd != nil }
        return activity.operationSessionEnd ?? .endedByOperation
    }
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

    #if DEBUG
    /// Binds a session identity with no `VZVirtualMachine` behind it; tests
    /// only.
    @MainActor func bindSessionForTesting(_ sessionID: UUID) {
        operation.activityForTesting.bindSession(withoutMachine: sessionID)
    }
    #endif
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
        case .bringUp(.starting), .bringUp(.restoringSavedState):
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
            .copyingOut:
            return .asStarted
        }
    }
}
