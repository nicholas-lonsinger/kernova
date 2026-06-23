import AppKit
import KernovaProtocol
import os

/// Owns the agent's menu-bar `NSStatusItem` and its dropdown.
///
/// The dropdown is informational + Quit only: clipboard/log enablement is
/// host-driven (the host pushes `PolicyUpdate`), so the menu reflects state
/// rather than offering switches that would fight host policy. Dynamic lines are
/// rebuilt each time the menu opens (`menuNeedsUpdate`) by pulling the current
/// state through the closures supplied at init; the status-item icon is updated
/// live via `connectionStateChanged(to:)` so it tracks the connection even while
/// the menu is closed.
@MainActor
final class GuestAgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "app.kernova.agent", category: "GuestAgentStatusItem")

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let version: String
    private let build: String
    private let connectionState: () -> HostConnectionState
    private let hostBundledVersion: () -> String
    private let clipboardActivity: () -> ClipboardActivity
    private let onQuit: () -> Void

    init(
        version: String,
        build: String,
        connectionState: @escaping () -> HostConnectionState,
        hostBundledVersion: @escaping () -> String,
        clipboardActivity: @escaping () -> ClipboardActivity,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.version = version
        self.build = build
        self.connectionState = connectionState
        self.hostBundledVersion = hostBundledVersion
        self.clipboardActivity = clipboardActivity
        self.onQuit = onQuit
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        setIcon(for: connectionState())
    }

    // MARK: - Icon

    /// Updates the menu-bar icon to reflect a connection-state change.
    ///
    /// Called by the app delegate from the control agent's `onStateChange`
    /// (hopped to main).
    func connectionStateChanged(to state: HostConnectionState) {
        setIcon(for: state)
    }

    private static func symbolName(for state: HostConnectionState) -> String {
        switch state {
        case .connected:
            return "antenna.radiowaves.left.and.right"
        case .connecting, .unresponsive:
            return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private func setIcon(for state: HostConnectionState) {
        let name = Self.symbolName(for: state)
        guard
            let image = NSImage(
                systemSymbolName: name, accessibilityDescription: "Kernova Guest Agent")
        else {
            // SF Symbol names are compile-time constants; a miss means a typo or a
            // deployment-target mismatch. Crash in debug, degrade to a glyph in release.
            Self.logger.fault("Missing SF Symbol '\(name, privacy: .public)' for status item")
            assertionFailure("Missing SF Symbol '\(name)'")
            statusItem.button?.image = nil
            statusItem.button?.title = "K"
            return
        }
        image.isTemplate = true
        statusItem.button?.title = ""
        statusItem.button?.image = image
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addInfoItem(GuestAgentMenuText.identity())

        let update = KernovaVersionComparison.updateState(
            own: version, hostBundled: hostBundledVersion())
        addInfoItem(
            GuestAgentMenuText.versionLine(version: version, build: build, update: update))

        menu.addItem(.separator())

        addInfoItem(GuestAgentMenuText.hostStatusLine(connectionState()))
        addInfoItem(GuestAgentMenuText.clipboardLine(clipboardActivity()))

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: GuestAgentMenuText.quit(), action: #selector(quitTapped), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Helpers

    /// Appends a disabled, informational (non-actionable) line.
    private func addInfoItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func quitTapped() {
        onQuit()
    }
}
