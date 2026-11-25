import Foundation

/// The vocabulary a VM's guest agent status is named in — the projection every
/// automation surface and every label reads off the app's agent status,
/// without the versions it carries: ``waiting`` until an agent has been seen,
/// then how the agent the status names stands.
///
/// Coded as one string, its ``rawValue``: `waiting`, or the agent's own name.
public enum VMAgentStatus: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
    /// No agent has connected yet: none may be set up, or the guest may still
    /// be starting.
    case waiting
    /// An agent has been seen, and stands as this says.
    case agent(VMAgentLineStatus)

    public static let allCases: [VMAgentStatus] = [.waiting] + VMAgentLineStatus.allCases.map(Self.agent)

    private static let waitingRawValue = "waiting"

    /// The name every automation surface reads this status by.
    public var rawValue: String {
        switch self {
        case .waiting: Self.waitingRawValue
        case .agent(let status): status.rawValue
        }
    }

    /// The status `rawValue` names, `nil` for a name no case has.
    public init?(rawValue: String) {
        if rawValue == Self.waitingRawValue {
            self = .waiting
        } else if let status = VMAgentLineStatus(rawValue: rawValue) {
            self = .agent(status)
        } else {
            return nil
        }
    }

    /// What a person reads for it: the Guest Agent Status window's heading.
    public var title: String {
        switch self {
        case .waiting: "No guest agent connected"
        case .agent(let status): status.title
        }
    }
}

/// How one guest agent that has been seen stands: ``VMAgentStatus``'s
/// vocabulary without ``VMAgentStatus/waiting``.
///
/// The raw value is the name every automation surface reads; ``title`` is
/// what a person reads.
public enum VMAgentLineStatus: String, Codable, CaseIterable, Sendable {
    case current, connected, outdated, reinstallNeeded, updating, unresponsive, expectedMissing, connecting
    case disconnected

    /// What a person reads for it: the Guest Agent Status window's heading.
    public var title: String {
        switch self {
        case .current: "Guest agent up to date"
        case .connected: "Guest agent connected"
        case .outdated: "Guest agent out of date"
        case .reinstallNeeded: "Guest agent can\u{2019}t update in place"
        case .updating: "Guest agent updating"
        case .unresponsive: "Guest agent not responding"
        case .expectedMissing: "Guest agent didn\u{2019}t reconnect"
        case .connecting: "Connecting to guest agent"
        case .disconnected: "Guest agent disconnected"
        }
    }
}
