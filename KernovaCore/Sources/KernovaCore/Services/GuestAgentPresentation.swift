import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaWire

/// What every surface shows of a VM's Kernova guest agent: one status, which
/// the icons, status lines and automation read, and — for a guest whose agents
/// the agent hub serves — each agent and each capability.
package struct GuestAgentPresentation: Equatable, Sendable {
    /// The agent's state as one value.
    package var status: AgentStatus
    /// The hub's agents and capabilities, `nil` for the macOS agent, which
    /// reports only `status`.
    package var hub: Hub?

    /// What the agent hub reports of a guest's agents.
    package struct Hub: Equatable, Sendable {
        /// One line per connected agent, newest first.
        package var peers: [PeerLine]
        /// One row per capability, in the order shown.
        package var capabilities: [CapabilityRow]
    }

    /// One connected agent.
    package struct PeerLine: Equatable, Sendable {
        /// Which agent: "Session agent — pbear", "System service".
        package var title: String
        /// What the line shows of it: whether it answers, then whether it is the
        /// agent Kernova bundles, or only its version where Kernova offers it
        /// nothing to compare against.
        package var state: String
    }

    /// One capability's availability.
    package struct CapabilityRow: Equatable, Sendable {
        /// What it does for the user.
        package var title: String
        /// Whether it is available now.
        package var isAvailable: Bool
        /// What it is doing while available, and why it is not otherwise.
        package var detail: String
    }

    /// The macOS agent's presentation: its control channel's `status`, nothing
    /// more.
    package init(macOSAgent status: AgentStatus) {
        self.status = status
        hub = nil
    }

    /// The presentation of the agents in `snapshot`, on the macOS agent's terms
    /// (``AgentStatus/synthesize(upstream:lastSeenAgentVersion:agentExpectedButMissing:)``):
    /// with no agent connected, a VM that has had one — `lastSeenAgentVersion`
    /// — is connecting to it; never waiting for an install. With `missing` —
    /// the scopes ``MissingAgentRule`` warns about — it didn't reconnect,
    /// naming the first missing scope's version, and each missing scope has a
    /// line of its own in place of any away line of that scope. An away peer
    /// otherwise keeps its line: one relaunching into an update keeps the
    /// standing it left with, counted in the status as though connected; any
    /// other reads as reconnecting.
    package init(
        hub snapshot: AgentHubSnapshot, lastSeenAgentVersion: String? = nil, missing: [AgentScopePresence] = []
    ) {
        let relaunching = snapshot.away.filter(\.relaunching).map(\.summary)
        status = AgentStatus.synthesize(
            upstream: Self.status(of: snapshot.peers + relaunching),
            lastSeenAgentVersion: missing.first?.lastSeenVersion ?? lastSeenAgentVersion,
            agentExpectedButMissing: !missing.isEmpty)
        let missingScopes = missing.map(\.scope)
        let away = snapshot.away.filter { !missingScopes.contains(AgentScopePresence.Scope(of: $0.summary)) }.map {
            away in
            PeerLine(
                title: Self.title(of: away.summary),
                state: away.relaunching ? Self.state(of: away.summary) : "Reconnecting\u{2026}")
        }
        hub = Hub(
            peers: snapshot.peers.map { peer in PeerLine(title: Self.title(of: peer), state: Self.state(of: peer)) }
                + away + missing.map(Self.missingLine),
            capabilities: [
                snapshot.peers.isEmpty
                    ? CapabilityRow(title: "Status", isAvailable: false, detail: Self.reason(.noAgent))
                    : CapabilityRow(title: "Status", isAvailable: true, detail: "Connected"),
                Self.row("Guest logs in Console", snapshot.features[.logs], availableDetail: "On"),
                Self.row("Automatic agent updates", snapshot.features[.update], availableDetail: "On"),
            ])
    }

    /// The row titled `title` for a feature whose merged status is `status`.
    private static func row(_ title: String, _ status: Availability<Data>, availableDetail: String) -> CapabilityRow {
        switch status {
        case .available: CapabilityRow(title: title, isAvailable: true, detail: availableDetail)
        case .absent(let reason, _): CapabilityRow(title: title, isAvailable: false, detail: Self.reason(reason))
        }
    }

    /// What `reason` means, as the user reads it.
    static func reason(_ reason: AbsenceReason) -> String {
        switch reason {
        case .noAgent: "No Kernova agent is connected."
        case .disabledByPolicy: "Turned off in Settings."
        case .versionMismatch, .protocolMismatch: "The agent is out of date."
        case .notImplemented: "This agent doesn't offer it."
        default: "Unavailable."
        }
    }

    /// The line of a scope ``MissingAgentRule`` warns about.
    private static func missingLine(_ presence: AgentScopePresence) -> PeerLine {
        switch presence.scope {
        case .system: PeerLine(title: "System service", state: "Didn\u{2019}t reconnect")
        case .login:
            PeerLine(title: "Session agent", state: "Didn\u{2019}t reconnect; it starts when a user logs in")
        }
    }

    private static func title(of peer: PeerSummary) -> String {
        switch peer.role {
        case .systemPeer: "System service"
        case .sessionPeer, .host: peer.userName.isEmpty ? "Session agent" : "Session agent — \(peer.userName)"
        }
    }

    /// How `peer` stands, as only what the host knows: whether it answers, and
    /// its version alone when the host offers it nothing to compare against.
    private static func state(of peer: PeerSummary) -> String {
        guard peer.isResponsive else { return "Not responding" }
        switch peer.standing {
        case .current: return "Up to date"
        case .outdated(_, .updating): return "Updating\u{2026}"
        case .outdated(_, .failed): return "Update failed"
        case .outdated(_, .unavailable): return "Out of date; this agent can\u{2019}t update itself"
        case .notOffered: return peer.versionLabel.isEmpty ? "Connected" : "Version \(peer.versionLabel)"
        }
    }

    /// The agents' state as one value: an outdated agent that is not updating
    /// itself first, then one that is, then an unresponsive one, else the
    /// newest — current only when every agent is, and connected when the host
    /// offers any of them nothing to judge it against.
    package static func status(of peers: [PeerSummary]) -> AgentStatus {
        guard let newest = peers.first else { return .waiting }
        var updating: AgentStatus?
        for peer in peers {
            guard case .outdated(let offered, let update) = peer.standing else { continue }
            if update != .updating { return .outdated(installed: peer.versionLabel, bundled: offered) }
            if updating == nil { updating = .updating(installed: peer.versionLabel, bundled: offered) }
        }
        if let updating { return updating }
        if let silent = peers.first(where: { !$0.isResponsive }) { return .unresponsive(version: silent.versionLabel) }
        return peers.allSatisfy { $0.standing == .current }
            ? .current(version: newest.versionLabel) : .connected(version: newest.versionLabel)
    }
}
