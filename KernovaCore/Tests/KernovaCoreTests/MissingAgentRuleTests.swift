import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// The maintainer's rule for when a missing guest agent warns, row by row, for
/// a macOS-shaped scope set (the login agent alone) and a Linux-shaped one (a
/// session and a system peer).
@Suite("MissingAgentRule", .caseScoped)
struct MissingAgentRuleTests {
    private static func login(
        lastSeen: String? = "1.0", seenThisSession: Bool = false, connected: Bool = false
    ) -> AgentScopePresence {
        AgentScopePresence(
            scope: .login, lastSeenVersion: lastSeen, seenThisSession: seenThisSession, isConnected: connected)
    }

    private static func system(
        lastSeen: String? = "1.0", seenThisSession: Bool = false, connected: Bool = false
    ) -> AgentScopePresence {
        AgentScopePresence(
            scope: .system, lastSeenVersion: lastSeen, seenThisSession: seenThisSession, isConnected: connected)
    }
}
