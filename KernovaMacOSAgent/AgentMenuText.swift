import Foundation

/// Pure text mappers for the guest agent's menu-bar dropdown.
enum AgentMenuText {
    static func about() -> String { "About Kernova Guest Agent" }

    /// Shown only when the host bundles a newer agent.
    static func updateAvailableLine(bundled: String) -> String {
        "Update available — host bundles \(bundled)"
    }

    static func hostStatusLine(_ state: HostConnectionState) -> String {
        switch state {
        case .connecting: return "Connecting to host…"
        case .connected: return "Connected to host"
        case .unresponsive: return "Host not responding"
        }
    }

    static func statusSubmenu() -> String { "Status" }

    static func logForwardingLine(_ enabled: Bool) -> String {
        "Log Forwarding: \(enabled ? "enabled" : "disabled")"
    }

    static func clipboardLine(_ activity: ClipboardActivity) -> String {
        switch activity {
        case .enabled: return "Clipboard: enabled"
        case .offeredToHost: return "Clipboard: shared with host"
        case .offeredFromHost: return "Clipboard: shared from host"
        case .sentToHost: return "Clipboard: sent to host"
        case .receivedFromHost: return "Clipboard: received from host"
        case .disabled: return "Clipboard: disabled"
        }
    }

    static func quit() -> String { "Quit Kernova Guest Agent" }
}
