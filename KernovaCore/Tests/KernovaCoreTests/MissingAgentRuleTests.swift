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

    @Test("Row 1: a scope never seen on the VM never warns")
    func neverSeen() {
        #expect(MissingAgentRule.missing([Self.login(lastSeen: nil)]).isEmpty)
        #expect(MissingAgentRule.missing([Self.login(lastSeen: nil), Self.system(lastSeen: nil)]).isEmpty)
    }

    @Test("Row 2: a login agent seen before but not yet this session warns, beside a connected system peer too")
    func loginNotYetThisSession() {
        #expect(MissingAgentRule.missing([Self.login()]) == [Self.login()])
        let linux = [Self.login(), Self.system(seenThisSession: true, connected: true)]
        #expect(MissingAgentRule.missing(linux) == [Self.login()])
    }

    @Test("Row 3: a login agent that connected this session never warns once it leaves")
    func loginSeenThisSession() {
        #expect(MissingAgentRule.missing([Self.login(seenThisSession: true)]).isEmpty)
        let linux = [Self.login(seenThisSession: true), Self.system(seenThisSession: true, connected: true)]
        #expect(MissingAgentRule.missing(linux).isEmpty)
    }

    @Test("Row 4: a system peer seen before warns whenever it is missing, seen this session or not")
    func systemMissing() {
        for seen in [false, true] {
            let linux = [Self.login(seenThisSession: true, connected: true), Self.system(seenThisSession: seen)]
            #expect(MissingAgentRule.missing(linux) == [Self.system(seenThisSession: seen)])
        }
    }

    @Test("A connected scope never warns")
    func connected() {
        #expect(MissingAgentRule.missing([Self.login(connected: true), Self.system(connected: true)]).isEmpty)
    }
}
