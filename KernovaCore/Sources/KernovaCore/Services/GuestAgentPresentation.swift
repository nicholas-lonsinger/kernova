import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaWire

/// What every surface shows of a VM's Kernova guest agents, as the agent hub
/// reports them: one status, which the icons, status lines and automation
/// read, then each agent and each capability.
package struct GuestAgentPresentation: Equatable, Sendable {
    /// The agents' state as one value.
    package var status: AgentStatus
    /// One line per agent: the connected ones newest first, then the away ones
    /// most recently gone first, then each scope that didn't reconnect.
    package var agents: [AgentLine]
    /// One row per capability, in the order shown.
    package var capabilities: [CapabilityRow]

    /// One agent, which the status window and `kernova info` both show.
    package struct AgentLine: Equatable, Sendable {
        /// Which agent it is.
        package enum Role: Equatable, Sendable {
            /// One GUI session's.
            case session
            /// The guest's as a whole.
            case system
        }

        /// Where the agent is, and how it stands while connected.
        package enum Standing: Equatable, Sendable {
            /// Connected: how it compares with the agent Kernova bundles, and
            /// whether it answers.
            case connected(PeerSummary.Standing, isResponsive: Bool)
            /// Away, relaunching into an update it installed; as it left.
            case relaunching(PeerSummary.Standing, isResponsive: Bool)
            /// Away, and expected back.
            case reconnecting
            /// A scope ``MissingAgentRule`` warns about: it didn't reconnect.
            case missing
        }

        package var role: Role
        /// The user a session agent runs for; `nil` for the system agent, one
        /// that names none, or a scope that didn't reconnect.
        package var user: String?
        /// The version it reports — for a scope that didn't reconnect, the one
        /// last seen — empty when there is none.
        package var version: String
        package var standing: Standing

        package init(role: Role, user: String?, version: String, standing: Standing) {
            self.role = role
            self.user = user
            self.version = version
            self.standing = standing
        }

        /// The line of `peer`, connected or away as `standing` says.
        init(_ peer: PeerSummary, standing: Standing) {
            let isSystem = peer.role == .systemPeer
            self.init(
                role: isSystem ? .system : .session, user: isSystem || peer.userName.isEmpty ? nil : peer.userName,
                version: peer.versionLabel, standing: standing)
        }

        /// The line of a scope ``MissingAgentRule`` warns about.
        init(missing presence: AgentScopePresence) {
            self.init(
                role: presence.scope == .system ? .system : .session, user: nil,
                version: presence.lastSeenVersion ?? "", standing: .missing)
        }

        /// Which agent: "Session agent — pbear", "System service".
        package var title: String {
            switch role {
            case .system: "System service"
            case .session: user.map { "Session agent — \($0)" } ?? "Session agent"
            }
        }

        /// What the line shows of it: whether it answers, then whether it is
        /// the agent Kernova bundles, or only its version where Kernova offers
        /// it nothing to compare against.
        package var state: String {
            switch standing {
            case .connected(let standing, let isResponsive), .relaunching(let standing, let isResponsive):
                guard isResponsive else { return "Not responding" }
                switch standing {
                case .current: return "Up to date"
                case .outdated(_, .updating): return "Updating\u{2026}"
                case .outdated(_, .failed): return "Update failed"
                case .outdated(_, .unavailable): return "Out of date; this agent can\u{2019}t update itself"
                case .notOffered: return version.isEmpty ? "Connected" : "Version \(version)"
                }
            case .reconnecting:
                return "Reconnecting\u{2026}"
            case .missing:
                switch role {
                case .system: return "Didn\u{2019}t reconnect"
                case .session: return "Didn\u{2019}t reconnect; it starts when a user logs in"
                }
            }
        }

        /// The agent's state alone: what the presentation's status would be
        /// with it the only agent for a connected one, updating for one relaunching into an update,
        /// connecting for any other away one, and expected-missing at its
        /// last-seen version for a scope that didn't reconnect.
        package var status: AgentStatus {
            switch standing {
            case .connected(let standing, let isResponsive):
                return GuestAgentPresentation.status(of: [(standing, isResponsive, version)])
            case .relaunching(let standing, _):
                guard case .outdated(let offered, _) = standing else {
                    return .updating(installed: version, bundled: "")
                }
                return .updating(installed: version, bundled: offered)
            case .reconnecting:
                return .connecting(expected: version)
            case .missing:
                return .expectedMissing(expected: version)
            }
        }
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

    /// The presentation of the agents in `snapshot`
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
        let away = snapshot.away.filter { !missingScopes.contains(GuestAgentScope(of: $0.summary)) }.map {
            away in
            AgentLine(
                away.summary,
                standing: away.relaunching
                    ? .relaunching(away.summary.standing, isResponsive: away.summary.isResponsive) : .reconnecting)
        }
        agents =
            snapshot.peers.map { AgentLine($0, standing: .connected($0.standing, isResponsive: $0.isResponsive)) }
            + away + missing.map(AgentLine.init(missing:))
        capabilities = [
            snapshot.peers.isEmpty
                ? CapabilityRow(title: "Status", isAvailable: false, detail: Self.reason(.noAgent))
                : CapabilityRow(title: "Status", isAvailable: true, detail: "Connected"),
            Self.row("Guest logs in Console", snapshot.features[.logs], availableDetail: "On"),
            Self.row("Automatic agent updates", snapshot.features[.update], availableDetail: "On"),
            Self.powerRow(snapshot),
        ]
    }

    /// The shutdown row: the routing running now, else the agent a Stop or
    /// Restart would ask, else why none would.
    private static func powerRow(_ snapshot: AgentHubSnapshot) -> CapabilityRow {
        let title = "Shut down and restart from Kernova"
        if let routing = snapshot.routing {
            let detail =
                switch routing.stage {
                case .askingApps: "Asking apps to quit\u{2026}"
                case .waitingOnApps(let apps):
                    "Waiting on \(ListFormatter.localizedString(byJoining: apps.map(\.displayName)))"
                case .asking, .accepted: "Shutting down\u{2026}"
                }
            return CapabilityRow(title: title, isAvailable: true, detail: detail)
        }
        switch snapshot.power {
        case .agent(.systemPeer):
            return CapabilityRow(title: title, isAvailable: true, detail: "Through the system service")
        case .agent:
            return CapabilityRow(title: title, isAvailable: true, detail: "Through the session agent")
        case .absent(.notOnConsole):
            return CapabilityRow(
                title: title, isAvailable: false,
                detail:
                    "Available to the session at the guest\u{2019}s screen, or to the system service at the login window."
            )
        case .absent(let reason):
            return CapabilityRow(title: title, isAvailable: false, detail: Self.reason(reason))
        }
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

    /// The agents' state as one value: an outdated agent that is not updating
    /// itself first, then one that is, then an unresponsive one, else the
    /// newest — current only when every agent is, and connected when the host
    /// offers any of them nothing to judge it against.
    package static func status(of peers: [PeerSummary]) -> AgentStatus {
        status(of: peers.map { ($0.standing, $0.isResponsive, $0.versionLabel) })
    }

    /// The same, of agents given by how each stands, whether it answers, and
    /// its version.
    fileprivate static func status(
        of agents: [(standing: PeerSummary.Standing, isResponsive: Bool, version: String)]
    ) -> AgentStatus {
        guard let newest = agents.first else { return .waiting }
        var updating: AgentStatus?
        for agent in agents {
            guard case .outdated(let offered, let update) = agent.standing else { continue }
            if update != .updating { return .outdated(installed: agent.version, bundled: offered) }
            if updating == nil { updating = .updating(installed: agent.version, bundled: offered) }
        }
        if let updating { return updating }
        if let silent = agents.first(where: { !$0.isResponsive }) { return .unresponsive(version: silent.version) }
        return agents.allSatisfy { $0.standing == .current }
            ? .current(version: newest.version) : .connected(version: newest.version)
    }
}
