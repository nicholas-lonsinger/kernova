import Foundation

/// String library for the sidebar agent-status popover content.
///
/// Split out from ``AgentStatusPopoverViewController`` so the per-status
/// title / body / action-button-title strings are pure-data, testable
/// without instantiating any view. Sizing is handled by AppKit auto
/// layout — the popover view controller publishes `view.fittingSize` as
/// `preferredContentSize` in `viewDidLayout`.
enum AgentStatusPopoverMetrics {
    static func title(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "Set up the Kernova guest agent"
        case .outdated: "Update available"
        case .connecting: "Connecting to guest agent"
        case .current: "Guest agent connected"
        case .unresponsive: "Guest agent unresponsive"
        case .expectedMissing: "Guest agent didn't reconnect"
        }
    }

    static func bodyText(for status: AgentStatus, vmName: String) -> String {
        switch status {
        case .waiting:
            return
                "The Kernova guest agent enables clipboard sync with \(vmName). "
                + "Mounting the installer presents it as a disk inside the VM — "
                + "open it in Finder and run install.command."
        case .outdated(let installed, let bundled):
            return
                "\(vmName) is running guest agent \(installed). Kernova bundles \(bundled). "
                + "Mounting the installer presents it as a disk inside the VM — open it "
                + "in Finder and run install.command."
        case .connecting(let expected):
            return
                "Waiting for guest agent \(expected) on \(vmName) to reconnect after boot. "
                + "If it doesn't connect within a couple of minutes, you'll see a "
                + "'didn't reconnect' indicator with reinstall steps."
        case .current(let version):
            return "\(vmName) is connected with guest agent \(version)."
        case .unresponsive(let version):
            return
                "\(vmName) (guest agent \(version)) stopped responding to heartbeats. "
                + "The control connection will reset automatically; if it persists, "
                + "restart the agent inside the VM."
        case .expectedMissing(let expected):
            return
                "\(vmName) had guest agent \(expected) installed previously, but it "
                + "didn't connect after this boot. The agent's LaunchAgent may be "
                + "unloaded, or it may have been uninstalled inside the VM. Reinstalling "
                + "presents the installer as a disk — open it in Finder and run install.command."
        }
    }

    /// Title for the popover's primary action button.
    ///
    /// `.current`, `.unresponsive`, `.connecting` cases return "Done" — no
    /// install/update flow helps; the button just closes the popover.
    static func actionButtonTitle(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "Install Guest Agent…"
        case .outdated: "Update Guest Agent…"
        case .current, .unresponsive, .connecting: "Done"
        case .expectedMissing: "Reinstall Guest Agent…"
        }
    }
}
