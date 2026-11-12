import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaAgentRuntime
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore

@Suite("Agent absence deadlines", .caseScoped)
struct AgentAbsenceDeadlinesTests {
    private static let floor = SystemScheduler().now
    private static let grace = Duration.seconds(120)
    private static let rollback = Duration.seconds(UpdateRollbackPolicy.latestRevertSeconds)

    private static func peer(_ role: PeerRole) -> PeerSummary {
        PeerSummary(
            handle: PeerHandle(rawValue: 1), role: role, scope: role == .systemPeer ? .system : .user, os: .linux,
            sessionID: "2", userName: role == .systemPeer ? "" : "pbear", console: .on, versionLabel: "1.0",
            standing: .current, isResponsive: true)
    }

    private static func away(
        _ role: PeerRole, order: UInt64, after offset: Duration, relaunching: Bool = false
    ) -> AwayPeer {
        AwayPeer(summary: peer(role), relaunching: relaunching, order: order, since: floor + offset)
    }

    /// A scope remembered on this VM, absent now; `seen` says whether it connected this session.
    private static func absent(_ scope: GuestAgentScope, seen: Bool = false) -> AgentScopePresence {
        AgentScopePresence(scope: scope, lastSeenVersion: "1.0", seenThisSession: seen, isConnected: false)
    }

    private static func pending(
        _ presences: [AgentScopePresence], away: [AwayPeer] = [], warned: Set<GuestAgentScope> = [],
        expired: Set<UInt64> = []
    ) -> [AgentAbsence.Subject: CoreInstant] {
        let absences = AgentAbsenceDeadlines.pending(
            presences: presences, away: away, floor: floor, grace: grace, warned: warned, expired: expired)
        return Dictionary(uniqueKeysWithValues: absences.map { ($0.subject, $0.deadline) })
    }

    @Test("A missing scope counts from its newest away peer, expired or not, and takes its relaunch")
    func scopeFromItsNewestAwayPeer() {
        let older = Self.away(.systemPeer, order: 1, after: .seconds(5))
        let newer = Self.away(.systemPeer, order: 3, after: .seconds(40), relaunching: true)
        let otherScope = Self.away(.sessionPeer, order: 4, after: .seconds(90))
        #expect(
            Self.pending(
                [Self.absent(.system), Self.absent(.login, seen: true)], away: [otherScope, newer, older],
                expired: [3, 1, 4]) == [.scope(.system): Self.floor + .seconds(40) + Self.grace + Self.rollback])
    }
}

extension CoreInstant {
    /// The instant `duration` later; tests only.
    static func + (lhs: CoreInstant, rhs: Duration) -> CoreInstant { lhs.advanced(by: CoreDuration(rhs)) }
}
