import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
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
    private static func absent(_ scope: AgentScopePresence.Scope, seen: Bool = false) -> AgentScopePresence {
        AgentScopePresence(scope: scope, lastSeenVersion: "1.0", seenThisSession: seen, isConnected: false)
    }

    private static func pending(
        _ presences: [AgentScopePresence], away: [AwayPeer] = [], warned: Set<AgentScopePresence.Scope> = [],
        expired: Set<UInt64> = []
    ) -> [AgentAbsence.Subject: CoreInstant] {
        let absences = AgentAbsenceDeadlines.pending(
            presences: presences, away: away, floor: floor, grace: grace, warned: warned, expired: expired)
        return Dictionary(uniqueKeysWithValues: absences.map { ($0.subject, $0.deadline) })
    }

    @Test("A missing scope with no away peer is waited for from the floor")
    func scopeFromTheFloor() {
        #expect(Self.pending([Self.absent(.login)]) == [.scope(.login): Self.floor + Self.grace])
    }

    @Test("An away peer is waited for from when it left; one relaunching into an update through the rollback too")
    func awayFromItsOwnStart() {
        let plain = Self.away(.sessionPeer, order: 2, after: .seconds(30))
        let relaunching = Self.away(.systemPeer, order: 1, after: .seconds(10), relaunching: true)
        #expect(
            Self.pending([Self.absent(.login, seen: true)], away: [plain, relaunching]) == [
                .away(order: 2): Self.floor + .seconds(30) + Self.grace,
                .away(order: 1): Self.floor + .seconds(10) + Self.grace + Self.rollback,
            ])
    }

    @Test("An absence that began before the floor counts from the floor")
    func neverBeforeTheFloor() {
        let early = Self.away(.systemPeer, order: 1, after: .seconds(-50))
        #expect(
            Self.pending([Self.absent(.system)], away: [early]) == [
                .away(order: 1): Self.floor + Self.grace, .scope(.system): Self.floor + Self.grace,
            ])
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

    @Test("A warned scope, a scope the rule doesn't find missing, and an expired away peer are not waited for")
    func nothingPendingTwice() {
        let gone = Self.away(.sessionPeer, order: 1, after: .seconds(1))
        let connected = AgentScopePresence(
            scope: .system, lastSeenVersion: "1.0", seenThisSession: true, isConnected: true)
        #expect(
            Self.pending(
                [Self.absent(.login), connected], away: [gone], warned: [.login], expired: [1]
            ).isEmpty)
    }

    @Test("Evaluating again with the same state gives the same deadlines")
    func stable() {
        let away = [Self.away(.systemPeer, order: 1, after: .seconds(3), relaunching: true)]
        let presences = [Self.absent(.login), Self.absent(.system)]
        #expect(Self.pending(presences, away: away) == Self.pending(presences, away: away))
    }
}

extension CoreInstant {
    /// The instant `duration` later; tests only.
    static func + (lhs: CoreInstant, rhs: Duration) -> CoreInstant { lhs.advanced(by: CoreDuration(rhs)) }
}
