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
    /// bundles, and can't take it in place for `reason`: only a reinstall from
    /// the installer disk puts the bundled agent in.
    case reinstallNeeded(installed: String, bundled: String, reason: ReinstallReason)

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
    /// Synthesized only by
    /// ``synthesize(upstream:lastSeenAgentVersion:agentExpectedButMissing:departedVersion:)``.
    case expectedMissing(expected: String)

    /// A VM that has had an agent connect before
    /// (`VMConfiguration.lastSeenAgentVersion` is set), with none connected
    /// right now and one still awaited — an agent that has yet to arrive, or
    /// one that went away within its grace.
    ///
    /// Resolves once an agent connects; to `.expectedMissing` when the agent
    /// absence watchdog warns; or to `.disconnected` once nothing is awaited
    /// and only a scope that left this session remains. Synthesized only by
    /// ``synthesize(upstream:lastSeenAgentVersion:agentExpectedButMissing:departedVersion:)``.
    case connecting(expected: String)

    /// A VM whose session agent connected during this session and left, its
    /// grace passed, with no agent connected now and none awaited: the
    /// absence ``MissingAgentRule`` never warns about, since a logout looks
    /// the same to the host as an uninstall. `last` is the version it last
    /// reported.
    ///
    /// Resolves once an agent connects. Synthesized only by
    /// ``synthesize(upstream:lastSeenAgentVersion:agentExpectedButMissing:departedVersion:)``.
    case disconnected(last: String)

    /// Why an agent can't take the bundled payload in place.
    package enum ReinstallReason: Equatable, Sendable {
        /// It refused the payload because the bundled agent's signature fails
        /// its own launch requirement.
        case launchRefused
        /// The payload this host bundles was signed with no team, so the host
        /// offers it to no agent in place.
        case notTeamSigned
    }

    package var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Resolves an upstream `AgentStatus` plus persisted host-side context into
    /// the final status the UI should render.
    ///
    /// Called only inside a session. Precedence: `.expectedMissing` (the
    /// watchdog warned) beats `upstream` unless it is `.waiting`, which
    /// becomes `.disconnected` when `departedVersion` names a scope that left
    /// with nothing awaited, else `.connecting` (agent seen before, none
    /// connected). Each synthesized case requires a non-empty version, which
    /// the UI renders beside it; with an empty one the next rule wins.
    static func synthesize(
        upstream: AgentStatus,
        lastSeenAgentVersion: String?,
        agentExpectedButMissing: Bool,
        departedVersion: String?
    ) -> AgentStatus {
        if agentExpectedButMissing,
            let expected = lastSeenAgentVersion,
            !expected.isEmpty
        {
            return .expectedMissing(expected: expected)
        }
        guard case .waiting = upstream else { return upstream }
        if let departed = departedVersion, !departed.isEmpty {
            return .disconnected(last: departed)
        }
        if let lastSeen = lastSeenAgentVersion, !lastSeen.isEmpty {
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
        case .reinstallNeeded: "reinstallNeeded"
        case .updating: "updating"
        case .unresponsive: "unresponsive"
        case .expectedMissing: "expectedMissing"
        case .connecting: "connecting"
        case .disconnected: "disconnected"
        }
    }
}
