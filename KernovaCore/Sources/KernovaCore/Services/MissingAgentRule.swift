import KernovaCommandModel

/// One scope of a VM's guest agents, as ``MissingAgentRule`` reads it, within
/// one VM session (from Start until the VM stops).
package struct AgentScopePresence: Equatable, Sendable {
    /// The scope.
    package var scope: GuestAgentScope
    /// The version an agent of the scope last reported on this VM, this
    /// session or an earlier one; nil when none ever connected.
    package var lastSeenVersion: String?
    /// An agent of the scope connected during this session.
    package var seenThisSession: Bool
    /// An agent of the scope is connected now.
    package var isConnected: Bool

    package init(scope: GuestAgentScope, lastSeenVersion: String?, seenThisSession: Bool, isConnected: Bool) {
        self.scope = scope
        self.lastSeenVersion = lastSeenVersion
        self.seenThisSession = seenThisSession
        self.isConnected = isConnected
    }
}

/// When a missing guest agent warns ("didn't reconnect", with Reinstall), for
/// every guest OS alike — the maintainer's rule:
///
/// | Scope's agent | Absent past the grace |
/// |---|---|
/// | never seen on this VM | no warning |
/// | login, seen before but not yet this session | warns |
/// | login, connected earlier this session | never warns: a logout or crash is not a missing install |
/// | system, seen before | warns |
package enum MissingAgentRule {
    /// Whether `presence`'s absence warns once the grace has passed.
    package static func warnsAfterGrace(_ presence: AgentScopePresence) -> Bool {
        guard presence.lastSeenVersion != nil, !presence.isConnected else { return false }
        switch presence.scope {
        case .login: return !presence.seenThisSession
        case .system: return true
        }
    }

    /// The scopes of `presences` whose absence warns once the grace has passed.
    package static func missing(_ presences: [AgentScopePresence]) -> [AgentScopePresence] {
        presences.filter(warnsAfterGrace)
    }
}
