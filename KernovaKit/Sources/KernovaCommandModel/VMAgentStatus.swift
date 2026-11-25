import Foundation

/// The vocabulary a guest agent's status is named in — the projection every
/// automation surface and every label reads off the app's agent status,
/// without the versions it carries.
///
/// The raw value is the name every automation surface reads; ``title`` is
/// what a person reads.
public enum VMAgentStatus: String, Codable, CaseIterable, Sendable {
    case waiting, current, connected, outdated, reinstallNeeded, updating, unresponsive, expectedMissing
    case connecting, disconnected

    /// What a person reads for it: the Guest Agent Status window's title.
    public var title: String {
        switch self {
        case .waiting: "Set up the Kernova guest agent"
        case .current: "Guest agent up to date"
        case .connected: "Guest agent connected"
        case .outdated: "Update available"
        case .reinstallNeeded: "Guest agent can\u{2019}t update in place"
        case .updating: "Updating guest agent"
        case .unresponsive: "Guest agent unresponsive"
        case .expectedMissing: "Guest agent didn\u{2019}t reconnect"
        case .connecting: "Connecting to guest agent"
        case .disconnected: "Guest agent disconnected"
        }
    }
}
