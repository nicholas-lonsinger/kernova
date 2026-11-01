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

    /// The presentation of the agents in `snapshot`.
    package init(hub snapshot: AgentHubSnapshot) {
        status = Self.status(of: snapshot.peers)
        hub = Hub(
            peers: snapshot.peers.map { peer in PeerLine(title: Self.title(of: peer), state: Self.state(of: peer)) },
            capabilities: [
                snapshot.peers.isEmpty
                    ? CapabilityRow(title: "Status", isAvailable: false, detail: Self.reason(.noAgent))
                    : CapabilityRow(title: "Status", isAvailable: true, detail: "Connected"),
                Self.row("Guest logs in Console", snapshot.features[.logs], availableDetail: "On"),
                Self.powerRow(snapshot),
            ])
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
                    "Waiting on \(ListFormatter.localizedString(byJoining: apps.map(\.shownName).filter { !$0.isEmpty }))"
                case .asking, .accepted: "Shutting down\u{2026}"
                }
            return CapabilityRow(title: title, isAvailable: true, detail: detail)
        }
        switch snapshot.power {
        case .agent(.systemPeer):
            return CapabilityRow(title: title, isAvailable: true, detail: "Through the system service")
        case .agent:
            return CapabilityRow(title: title, isAvailable: true, detail: "Through the session agent")
        case .absent(let reason):
            let detail =
                switch reason {
                case .notOnConsole:
                    """
                    Available while the session agent\u{2019}s user is at the guest\u{2019}s screen, or with the system \
                    service installed while no one is logged in to a desktop.
                    """
                case .unsavedWorkUnseen: "Kernova\u{2019}s agents can\u{2019}t see this desktop\u{2019}s unsaved work."
                case .notPermitted: "The guest doesn\u{2019}t permit its agents to shut it down."
                case .missingOsComponent: "This guest has no polkit."
                default: Self.reason(reason)
                }
            return CapabilityRow(title: title, isAvailable: false, detail: detail)
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
        case .outdated: return "Out of date"
        case .notOffered: return peer.versionLabel.isEmpty ? "Connected" : "Version \(peer.versionLabel)"
        }
    }

    /// The agents' state as one value: an outdated agent first, then an
    /// unresponsive one, else the newest — current only when every agent is,
    /// and connected when the host offers any of them nothing to judge it
    /// against.
    package static func status(of peers: [PeerSummary]) -> AgentStatus {
        guard let newest = peers.first else { return .waiting }
        for peer in peers {
            if case .outdated(let offered) = peer.standing {
                return .outdated(installed: peer.versionLabel, bundled: offered)
            }
        }
        if let silent = peers.first(where: { !$0.isResponsive }) { return .unresponsive(version: silent.versionLabel) }
        return peers.allSatisfy { $0.standing == .current }
            ? .current(version: newest.versionLabel) : .connected(version: newest.versionLabel)
    }
}
