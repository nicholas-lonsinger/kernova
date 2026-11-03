import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel

/// One absence the agent absence watchdog waits out, and when it stops waiting.
package struct AgentAbsence: Equatable, Sendable {
    /// What is absent.
    package enum Subject: Hashable, Sendable {
        /// An away peer of the hub's snapshot, by its ``AwayPeer/order``: at the deadline its line goes.
        case away(order: UInt64)
        /// A scope ``MissingAgentRule`` finds missing: at the deadline it warns.
        case scope(GuestAgentScope)
    }

    package var subject: Subject
    /// On the platform's monotonic timeline (`SystemScheduler`), as ``AwayPeer/since`` is.
    package var deadline: CoreInstant
}

/// When each absence of a VM's guest agents stops being waited for: a pure function of what is absent now,
/// so evaluating it again never moves a deadline.
package enum AgentAbsenceDeadlines {
    /// The absences still waited for, each with its deadline: its effective start — its own start, never
    /// earlier than `floor`, the moment the guest last began running under the watchdog — plus its allowance.
    ///
    /// - An away peer not in `expired` starts at its ``AwayPeer/since``.
    /// - A scope ``MissingAgentRule`` finds missing in `presences`, not in `warned`, starts at the `since` of
    ///   the newest away peer of that scope, expired or not, and at `floor` with none.
    ///
    /// The allowance is `grace`, and for an absence that is a peer relaunching into an update the rollback
    /// window on top, since the guest reverts a new version that never connects only that late
    /// (``UpdateRollbackPolicy``).
    package static func pending(
        presences: [AgentScopePresence], away: [AwayPeer], floor: CoreInstant, grace: Duration,
        warned: Set<GuestAgentScope>, expired: Set<UInt64>
    ) -> [AgentAbsence] {
        func deadline(since: CoreInstant, relaunching: Bool) -> CoreInstant {
            let allowance = relaunching ? grace + .seconds(UpdateRollbackPolicy.latestRevertSeconds) : grace
            return max(since, floor).advanced(by: CoreDuration(allowance))
        }
        let awayLines = away.filter { !expired.contains($0.order) }.map { peer in
            AgentAbsence(
                subject: .away(order: peer.order), deadline: deadline(since: peer.since, relaunching: peer.relaunching))
        }
        let scopes = MissingAgentRule.missing(presences).filter { !warned.contains($0.scope) }.map { presence in
            let newest = away.filter { GuestAgentScope(of: $0.summary) == presence.scope }
                .max { $0.order < $1.order }
            return AgentAbsence(
                subject: .scope(presence.scope),
                deadline: deadline(since: newest?.since ?? floor, relaunching: newest?.relaunching ?? false))
        }
        return awayLines + scopes
    }
}

extension CoreDuration {
    /// `duration`, to the nanosecond, saturating.
    package init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (total, sumOverflow) = whole.addingReportingOverflow(attoseconds / 1_000_000_000)
        self.init(nanoseconds: overflow || sumOverflow ? (seconds < 0 ? .min : .max) : total)
    }
}

extension GuestAgentScope {
    /// The scope `peer` is an agent of.
    package init(of peer: PeerSummary) {
        self = peer.role == .systemPeer ? .system : .login
    }
}
