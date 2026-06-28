import Foundation
import KernovaKit

/// Pure text mappers for the guest agent's menu-bar dropdown.
///
/// Free of AppKit so they're trivially unit-testable; `GuestAgentStatusItemController`
/// calls them when (re)building menu lines in `menuNeedsUpdate`.
enum GuestAgentMenuText {
    /// "About" command title — opens the standard About panel, which carries
    /// the identity, version/build, and copyright moved out of the dropdown.
    static func about() -> String { "About Kernova Guest Agent" }

    /// Top-level hint shown only when the host bundles a newer agent.
    ///
    /// Used as the About panel's credits string for the same case; the
    /// up-to-date / unknown cases show nothing — version/build live in the
    /// About panel.
    static func updateAvailableLine(bundled: String) -> String {
        "Update available — host bundles \(bundled)"
    }

    /// Host control-channel status line.
    static func hostStatusLine(_ state: HostConnectionState) -> String {
        switch state {
        case .connecting: return "Connecting to host…"
        case .connected: return "Connected to host"
        case .unresponsive: return "Host not responding"
        }
    }

    /// Title of the submenu grouping the host-driven capability lines.
    static func statusSubmenu() -> String { "Status" }

    /// Log-forwarding capability line.
    static func logForwardingLine(_ enabled: Bool) -> String {
        "Log Forwarding: \(enabled ? "enabled" : "disabled")"
    }

    /// Clipboard sharing state line.
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

    /// Top-level hint shown when large-file clipboard paste needs enabling.
    ///
    /// Surfaced when the File Provider extension's per-extension System-Settings
    /// toggle is off; informational, paired with the actionable command below.
    static func fileProviderNeedsEnablingLine() -> String {
        "Large-file paste needs enabling"
    }

    /// Actionable command opening System Settings to enable the extension.
    ///
    /// Ellipsis: it navigates to System Settings to gather the user's action.
    static func fileProviderEnableCommand() -> String {
        "Enable in System Settings…"
    }

    /// Quit command title.
    static func quit() -> String { "Quit Kernova Guest Agent" }
}
