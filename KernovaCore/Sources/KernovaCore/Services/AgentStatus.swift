import Foundation

/// Whether the guest agent is installed and current relative to what the host
/// bundles, and whether it's actively responding.
package enum AgentStatus: Equatable, Sendable {
    /// No agent has connected yet — the agent may not be installed, or the VM
    /// may still be booting.
    case waiting

    /// The guest agent is connected and runs the payload the host bundles.
    case current(version: String)

    /// The guest agent is connected, and the host bundles nothing to judge its
    /// version against.
    case connected(version: String)

    /// The guest agent is connected but runs a payload other than the one the
    /// host bundles, and is not updating itself to it.
    case outdated(installed: String, bundled: String)

    /// The guest agent is connected, runs a payload other than the one the host
    /// bundles, and is updating itself to it in-band.
    case updating(installed: String, bundled: String)

    /// The guest agent is connected but the hub judges it unresponsive.
    case unresponsive(version: String)

    /// The host has seen the agent connect on this VM before
    /// (`VMConfiguration.lastSeenAgentVersion` is set), but a grace period
    /// elapsed with none connected — after the VM started or resumed, or after
    /// the agent went away mid-session (``MissingAgentRule``).
    ///
    /// Synthesized only by ``synthesize(upstream:lastSeenAgentVersion:agentExpectedButMissing:)``.
    case expectedMissing(expected: String)

    /// A VM that has had an agent connect before
    /// (`VMConfiguration.lastSeenAgentVersion` is set), with none connected
    /// right now — the agent has yet to arrive, or arrived and then went away.
    ///
    /// Resolves once an agent connects, or to `.expectedMissing` if the agent
    /// absence watchdog fires. Synthesized only by
    /// ``synthesize(upstream:lastSeenAgentVersion:agentExpectedButMissing:)``.
    case connecting(expected: String)

    package var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Resolves an upstream `AgentStatus` plus persisted host-side context into
    /// the final status the UI should render.
    ///
    /// Called only inside a session. Precedence: `.expectedMissing` (the
    /// watchdog fired) beats `.connecting` (agent seen before, none connected)
    /// beats `upstream` unchanged. Both synthesized cases require a non-empty
    /// `lastSeenAgentVersion` — with an empty one the UI renders "guest agent
    /// didn't reconnect", so upstream wins instead.
    static func synthesize(
        upstream: AgentStatus,
        lastSeenAgentVersion: String?,
        agentExpectedButMissing: Bool
    ) -> AgentStatus {
        if agentExpectedButMissing,
            let expected = lastSeenAgentVersion,
            !expected.isEmpty
        {
            return .expectedMissing(expected: expected)
        }
        if case .waiting = upstream,
            let lastSeen = lastSeenAgentVersion,
            !lastSeen.isEmpty
        {
            return .connecting(expected: lastSeen)
        }
        return upstream
    }

    /// The name automation surfaces read this status by, without the versions
    /// the UI renders alongside it.
    var wireName: String {
        switch self {
        case .waiting: "waiting"
        case .current: "current"
        case .connected: "connected"
        case .outdated: "outdated"
        case .updating: "updating"
        case .unresponsive: "unresponsive"
        case .expectedMissing: "expectedMissing"
        case .connecting: "connecting"
        }
    }
}
