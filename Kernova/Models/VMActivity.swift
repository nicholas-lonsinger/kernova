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

    /// Drops a suspend slot a save is still part-way through writing, the first
    /// step of taking in a session that stopped with an error.
    func dropTruncatedSaveFile()

    /// Called once the session is released, after the VM has rested.
    func sessionDidEnd()

    /// Called once a power-off has released the session, before
    /// ``VMActivity/onPoweredOff`` fires.
    func guestDidPowerOff()
}

/// Where a VM is in its lifecycle, and the live session it holds.
///
/// The only writer of ``phase`` and ``sessionContext``, which it releases
/// together.
@MainActor
@Observable
final class VMActivity {
    /// The VM this activity belongs to.
    ///
    /// Set by the owner as it is created.
    @ObservationIgnored weak var owner: (any VMActivityOwner)?

    /// Where this VM is in its lifecycle — the one stored value its status, its
    /// failure message and every liveness predicate here are read off.
    ///
    /// Moved by ``enter(_:)`` for a transition that names no session, by
    /// ``beginBringUp(_:)`` to leave rest for a bring-up, by
    /// ``attachSession(from:)`` to name the session a bring-up created, by
    /// ``settle(_:for:)`` for one concluding work a session did, and by
    /// ``tearDownSession(restingAt:)``, which releases the session and rests in
    /// the same call.
    private(set) var phase: VMLifecyclePhase

    /// Everything scoped to the current `VZVirtualMachine`'s lifetime.
    ///
    /// Replaced only by ``beginSessionContext(_:)``, which tears down the one it
    /// displaces, and released whole only by ``tearDownSession(restingAt:)``, in
    /// the same call that rests the phase.
    private(set) var sessionContext: VMSessionContext?

    /// The live VM's isolation domain — the only type that calls into the
    /// `VZVirtualMachine` and its device objects.
    var session: VMSession? { sessionContext?.session }

    /// The vocabulary the wire and every label read.
    var status: VMStatus { phase.status }

    /// The permanent-failure message the error banner and the status tooltip
    /// show.
    ///
    /// A payload of ``VMLifecyclePhase/failed(message:)`` rather than a field of
    /// its own, so it cannot survive the move to another phase.
    var errorMessage: String? { phase.errorMessage }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMActivity")

    init(phase: VMLifecyclePhase) {
        self.phase = phase
    }

    private var name: String { owner?.name ?? "" }

    // MARK: - Hooks

    /// The live VM whose identity bringing this one up would duplicate, or `nil`
    /// when nothing collides — what ``beginBringUp(_:)`` refuses on.
    ///
    /// Wired by `VMLibrary.wireHooks(for:)`; an instance outside a library has
    /// no peers, and passes.
    @ObservationIgnored var liveIdentityConflict: (@MainActor () -> VMIdentityConflict?)?

    /// Fired from ``restAfterPowerOff()`` — the guest powering off, however it got
    /// there: a graceful shutdown from inside, Stop, or Force Stop.
    ///
    /// Wired by `VMLibrary.wireHooks(for:)`, whose handler reverts an
    /// Ephemeral Mode VM to its baseline here. A suspend does not reach it:
    /// `save` tears the session down and rests at `.paused`.
    @ObservationIgnored var onPoweredOff: (@MainActor () -> Void)?

    /// Fired on the edge where this VM becomes something a device can be
    /// attached to — ``attachableSessionID`` going from `nil` to naming a
    /// session.
    ///
    /// An edge rather than every arrival at a live phase, so it fires once per
    /// session: a pause and resume both rest at attachable phases and must not
    /// re-run whatever this triggers.
    ///
    /// Wired by `VMLibrary.wireHooks(for:)`, whose handler hands the
    /// guest the accessories paired with it and starts watching its address.
    @ObservationIgnored var onSessionBecameAttachable: (@MainActor () -> Void)?

    // MARK: - Liveness

    /// The live session's identity — the token every asynchronous hand-off and
    /// delivered event carries, so one raised against a session this instance
    /// has already released is dropped instead of landing on its successor or
    /// on a stopped VM.
    ///
    /// Read off ``phase``, which is what makes the drop reliable: the phase and
    /// the session move together, so no window exists where a released session
    /// still answers as live.
    var liveSessionID: UUID? { phase.sessionID }

    /// Whether a `VZVirtualMachine` for this VM is live in memory — the single
    /// liveness read every predicate here shares.
    var hasLiveVirtualMachine: Bool { liveSessionID != nil }

    /// Whether a live `VZVirtualMachine` is attached and settled at a state VZ
    /// can act on — the VMs a termination save-suspends, and the ones a device
    /// can be attached to.
    ///
    /// A cold-paused VM is excluded: its state is already on disk, with nothing
    /// live to act on.
    var hasLiveSession: Bool { phase.hasLiveSession }

    /// The session a removable-media attach or detach acts on, or `nil` when
    /// the VM has none to act on.
    ///
    /// The token every step of a reconcile pass carries, so the pass and the
    /// capability it was admitted by cannot answer for different sessions.
    var attachableSessionID: UUID? { hasLiveSession ? liveSessionID : nil }

    /// `true` when the VM is paused-to-disk but has no live `VZVirtualMachine` in memory.
    var isColdPaused: Bool { phase.isColdPaused }

    /// `true` when the VM is paused with its `VZVirtualMachine` still live in
    /// memory — the in-memory counterpart of a suspension on disk.
    var isLivePaused: Bool { phase.isLivePaused }

    /// Whether this VM holds its identity against another's bring-up — see
    /// ``VMLifecyclePhase/holdsLiveIdentity``.
    var holdsLiveIdentity: Bool { phase.holdsLiveIdentity }

    /// `true` when the VM is settled with nothing live and no operation in
    /// flight — see ``VMLifecyclePhase/isAtRest``.
    var isAtRest: Bool { phase.isAtRest }

    /// `true` while the VM is in an active lifecycle phase — see
    /// ``VMLifecyclePhase/isActive``.
    var isActive: Bool { phase.isActive }

    /// `true` when this VM should keep the app alive: in an active lifecycle
    /// phase, or live-paused in memory.
    var isKeepingAppAlive: Bool {
        isActive || isLivePaused
    }

    /// `true` while the VM is mid-operation — see
    /// ``VMLifecyclePhase/isTransitioning``.
    var isTransitioning: Bool { phase.isTransitioning }

    /// Whether the VM has a display session a backing view should present.
    var hasActiveDisplay: Bool { phase.hasActiveDisplay }

    /// Where this VM rests once nothing is live: suspended while its suspend
    /// slot is on disk, `fallback` once it is not.
    ///
    /// The one derivation every teardown and every failure classification
    /// reads, so "at rest holding a slot" and ``VMLifecyclePhase/suspended``
    /// cannot come apart — whatever ended the live session, a saved session
    /// that survived it is what the VM comes back on.
    ///
    /// ``VMLifecyclePhase/initialBoot`` is the one at-rest phase chosen without
    /// it: a VM that has never finished its guest setup names that setup rather
    /// than a session, which is the order ``VMLibrary/initialPhase(for:layout:)``
    /// reads the bundle in too.
    func restingPhase(withoutSlot fallback: VMLifecyclePhase) -> VMLifecyclePhase {
        owner?.hasSaveFile == true ? .suspended : fallback
    }

    // MARK: - Session Events

    /// Builds the event sink a new session delivers into.
    ///
    /// Events hop to the main actor and apply only while the delivering
    /// session is still the one this instance holds: delivery is asynchronous,
    /// so a stop event from a torn-down session can arrive after a fresh
    /// session is attached and must not reset it.
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
            restAfterPowerOff()
            #log(Self.logger, .notice, "Guest stopped for VM '\(self.name, privacy: .public)'")
        case .didStopWithError(let error):
            owner?.dropTruncatedSaveFile()
            // A slot that survived carries a session the user can still come
            // back on, so the VM is resumable rather than stuck and takes no
            // message — the failure reaches the user as the event this raises.
            tearDownSession(
                restingAt: restingPhase(withoutSlot: .failed(message: error.localizedDescription)))
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

    // MARK: - Phase Transitions

    /// Places the VM at `phase`.
    ///
    /// The write every transition that names no session goes through — a
    /// disks-only capture, a revert, a discarded suspend slot — except leaving
    /// rest to bring a guest up, which is ``beginBringUp(_:)``. A phase that
    /// *does* name one is installed by ``settle(_:for:)`` or by
    /// ``attachSession(from:)``, and released by ``tearDownSession(restingAt:)``.
    func enter(_ phase: VMLifecyclePhase) {
        setPhase(phase)
    }

    #if DEBUG
    /// Puts the VM straight into `phase`, bypassing every rule a transition
    /// obeys; tests only, and the one way a test places a phase.
    func placeForTesting(_ phase: VMLifecyclePhase) {
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

    /// Applies `phase` only while `sessionID` still names the live session,
    /// reporting whether it landed.
    ///
    /// What every asynchronous operation concludes through, for the reason
    /// ``deliverSessionEvent(_:from:)`` exists: an operation's awaits give a
    /// `didStopWithError`, a force stop or a successor session time to land, and
    /// a phase written over that would claim a `VZVirtualMachine` this instance
    /// no longer holds — leaving a VM nothing can stop, force stop, or start.
    @discardableResult
    func settle(_ phase: VMLifecyclePhase, for sessionID: UUID) -> Bool {
        guard liveSessionID == sessionID else { return false }
        setPhase(phase)
        return true
    }

    /// Leaves rest for `bringUp`, refusing when another live VM already claims
    /// the machine identity or the MAC address this one would put in front of
    /// VZ (``liveIdentityConflict``).
    ///
    /// The check and the phase entry are one synchronous step, so the phase is
    /// what makes this VM live to every later check: of two twins, the second
    /// to arrive is refused by the first's bring-up still in flight. A refusal
    /// leaves the phase untouched.
    func beginBringUp(_ bringUp: VMBringUpPhase) throws(VMIdentityConflict) {
        if let conflict = liveIdentityConflict?() {
            #log(
                Self.logger, .notice,
                "Refused to bring up '\(self.name, privacy: .public)': \(conflict.errorDescription ?? "", privacy: .public)"
            )
            throw conflict
        }
        setPhase(bringUp.lifecyclePhase)
    }

    /// Ends a guest setup that ran no VZ session, so no power-off takes the VM
    /// out of ``VMLifecyclePhase/installing(sessionID:)`` — the Linux image
    /// pipeline, whose caller chains a Start straight off it.
    func endGuestSetup() {
        enter(.stopped)
    }

    // MARK: - Session Lifecycle

    /// Installs the context `make` opens as this VM's session context,
    /// releasing any prior one first.
    @discardableResult
    func beginSessionContext(_ make: () -> VMSessionContext) -> VMSessionContext {
        // A displaced context is released rather than dropped: the boot paths
        // tear down before retrying, so reaching here with one open means a
        // caller skipped that — and the dropped context's VZ session, pipes and
        // security scopes would outlive the last reference to them.
        sessionContext?.tearDown()
        let context = make()
        sessionContext = context
        return context
    }

    /// Takes the pipes and cold-attached removable media a configuration build
    /// produced into the open session context.
    func adoptBuildResult(_ result: ConfigurationBuilder.BuildResult) {
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

    /// Creates the VM on its own queue, stores the session, and promotes the
    /// in-flight phase to name it, answering the session and the context that
    /// now holds it.
    ///
    /// The promotion is part of storing the session rather than the caller's
    /// next step: liveness is read off the phase, so a gap between the two would
    /// be a window in which a `VZVirtualMachine` exists and every predicate
    /// answers that none does.
    ///
    /// `nil` when no session context is open, or when the phase admits no
    /// session identity to promote — both programming errors, since every
    /// bring-up path opens a context and stands in an admitting phase before
    /// building the configuration this takes. Either way the just-created
    /// `VZVirtualMachine` is released rather than handed back: a session this
    /// instance does not hold is one nothing can stop, so a caller starting it
    /// would leave the guest running past every liveness predicate, force stop
    /// included.
    func attachSession(
        from result: ConfigurationBuilder.BuildResult
    ) async -> (session: VMSession, context: VMSessionContext)? {
        // The configuration was assembled off-main and is handed over whole:
        // nothing touches it after the VM is created from it.
        nonisolated(unsafe) let vzConfig = result.configuration
        let session = await VMSession.make(configuration: vzConfig, events: makeSessionEvents())
        guard let sessionContext else {
            #log(
                Self.logger, .fault,
                "No session context to attach a session to for '\(self.name, privacy: .public)'")
            assertionFailure("attachSession without beginSessionContext for '\(name)'")
            return nil
        }
        guard let promoted = phase.naming(session.id) else {
            #log(
                Self.logger, .fault,
                "Session attached to '\(self.name, privacy: .public)' while at \(self.status.rawValue, privacy: .public), which names no session"
            )
            assertionFailure("attachSession from a phase that admits no session identity")
            return nil
        }
        sessionContext.session = session
        setPhase(promoted)
        return (session, sessionContext)
    }

    /// Tears the live VM session down and rests the VM at `phase`.
    ///
    /// The two are one call because a phase naming a session that is gone is
    /// exactly the state this type exists to make unrepresentable — so
    /// `restingAt` must name none. A retry that stays mid-operation passes
    /// the sessionless form of the phase it is in
    /// (``VMLifecyclePhase/starting(sessionID:)`` with `nil`, say).
    func tearDownSession(restingAt phase: VMLifecyclePhase) {
        if let strandedSessionID = phase.sessionID {
            #log(
                Self.logger, .fault,
                "Teardown of '\(self.name, privacy: .public)' asked to rest at a phase naming session \(strandedSessionID, privacy: .public)"
            )
            assertionFailure("tearDownSession(restingAt:) given a phase naming a session")
        }
        sessionContext?.tearDown()
        sessionContext = nil
        setPhase(phase)
        owner?.sessionDidEnd()
    }

    /// Releases the live session and rests the VM where one with nothing live
    /// belongs, firing ``onPoweredOff``.
    ///
    /// Stopped for the guest that simply went down, and suspended when the
    /// bundle still holds a slot — a session on disk survives whatever ended
    /// the live one, and is still the user's to come back on.
    func restAfterPowerOff() {
        tearDownSession(restingAt: restingPhase(withoutSlot: .stopped))
        owner?.guestDidPowerOff()
        onPoweredOff?()
    }
}
