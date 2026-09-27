import Foundation

/// Work nobody waits on that follows on one VM once the VM is free — the
/// Ephemeral baseline revert after a power-off, a paired accessory's attach.
///
/// Queued on the VM's ``VMActivity`` by ``VMActivity/follow(_:)``, or returned
/// by a hook the activity fires inside a commit step, and admitted only by the
/// activity's one drain: at once on a settled VM, and otherwise in the step
/// that frees it, before any other request can be decided against it.
@MainActor
struct VMFollowUp {
    /// How long a follow-up stays owed.
    enum Scope: Sendable, Equatable {
        /// Until the VM is removed.
        case vm
        /// Until the session `id` names ends.
        case session(UUID)
    }

    /// Where a follow-up drains among the others queued with it: every
    /// restoration before any ordinary one, and each rank in arrival order.
    enum Rank: Sendable, Comparable {
        /// Puts the VM back into a state it owes before anything else runs on
        /// it — the Ephemeral baseline revert.
        case restoration
        case ordinary
    }

    let scope: Scope
    let rank: Rank

    /// The request the follow-up makes of admission, when it is known before
    /// the follow-up drains; `nil` otherwise.
    ///
    /// A follow-up that names one joins, taking its outcome, rather than
    /// queueing: an operation holding the VM that admission says the request
    /// joins, or a follow-up already queued with the same request and scope.
    /// So one request is queued at most once, whichever path sends it.
    let request: VMAdmission.Request?

    /// What the follow-up's operation resolves when it ends, or the refusal
    /// that ended the follow-up without running it — made before it is
    /// queued, so its owner can await it from the start.
    let outcome: VMOutcome

    /// Decides the follow-up against the VM as it stands and, when admitted,
    /// launches its operation to resolve the outcome it is handed; throws the
    /// refusal otherwise, which the drain resolves the outcome with.
    let admit: @MainActor (VMOutcome) throws -> Void

    init(
        scope: Scope, rank: Rank, request: VMAdmission.Request? = nil,
        outcome: VMOutcome = VMOutcome(),
        admit: @escaping @MainActor (VMOutcome) throws -> Void
    ) {
        self.scope = scope
        self.rank = rank
        self.request = request
        self.outcome = outcome
        self.admit = admit
    }

    /// Hands `report` how the follow-up failed once its outcome resolves —
    /// the one filter every owner reports through, each over its own
    /// channel.
    ///
    /// Silent for the endings that are not failures of the work: the VM was
    /// removed, the app is terminating, the follow-up was withdrawn or
    /// cancelled, or the session it was scoped to is gone.
    func reportingFailure(_ report: @escaping @MainActor (any Error) -> Void) -> VMFollowUp {
        let outcome = outcome
        let scope = scope
        Task { @MainActor in
            do {
                try await outcome.value()
            } catch {
                guard Self.isReportable(error, scope: scope) else { return }
                report(error)
            }
        }
        return self
    }

    /// Whether a follow-up scoped to `scope` that ended with `error` failed in
    /// a way its owner reports.
    static func isReportable(_ error: any Error, scope: Scope) -> Bool {
        if error is CancellationError { return false }
        guard let refused = error as? VMAdmissionRefusal else { return true }
        switch refused.refusal {
        case .removed, .terminating:
            return false
        case .invalidState:
            guard case .session = scope else { return true }
            return false
        case .busy, .identityConflict, .accessoryHeld, .unsupportedByBuild, .heldByAnotherCopy:
            return true
        }
    }
}
