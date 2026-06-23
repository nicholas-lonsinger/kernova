import AppKit
import KernovaProtocol
import os

/// Owns the agent's menu-bar `NSStatusItem` and its dropdown.
///
/// The dropdown leads with live status (host connection, clipboard activity)
/// and offers About + Quit: clipboard/log enablement is host-driven (the host
/// pushes `PolicyUpdate`), so the menu reflects state rather than offering
/// switches that would fight host policy. Identity, version/build, and
/// copyright live in the standard About panel (`aboutTapped`); a pending agent
/// update also surfaces as a top-level hint line. Dynamic lines are rebuilt
/// each time the menu opens (`menuNeedsUpdate`) by pulling the current state
/// through the closures supplied at init; the status-item icon is updated live
/// via `connectionStateChanged()` so it tracks the connection even while the
/// menu is closed.
@MainActor
final class GuestAgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "app.kernova.agent", category: "GuestAgentStatusItem")

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let version: String
    private let connectionState: () -> HostConnectionState
    private let hostBundledVersion: () -> String
    private let clipboardActivity: () -> ClipboardActivity
    private let onQuit: () -> Void

    init(
        version: String,
        connectionState: @escaping () -> HostConnectionState,
        hostBundledVersion: @escaping () -> String,
        clipboardActivity: @escaping () -> ClipboardActivity,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.version = version
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
    /// (hopped to main). Re-reads the live (lock-guarded) state rather than
    /// trusting a delivered value: each off-main `onStateChange` is hopped
    /// through its own `Task { @MainActor }`, and independently-spawned tasks
    /// have no ordering guarantee, so a rapid connect/disconnect flap could
    /// arrive out of order — reading ground truth makes the icon converge on
    /// the real state regardless of arrival order.
    func connectionStateChanged() {
        setIcon(for: connectionState())
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

        // Lead with live status. Identity + version/build are reached through
        // the About item below; only an actionable pending update surfaces here.
        if case .updateAvailable(let bundled) = updateState() {
            addInfoItem(GuestAgentMenuText.updateAvailableLine(bundled: bundled))
            menu.addItem(.separator())
        }

        addInfoItem(GuestAgentMenuText.hostStatusLine(connectionState()))
        addInfoItem(GuestAgentMenuText.clipboardLine(clipboardActivity()))

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: GuestAgentMenuText.about(), action: #selector(aboutTapped), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(
            title: GuestAgentMenuText.quit(), action: #selector(quitTapped), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - About

    /// Opens the standard AppKit About panel.
    ///
    /// Name, version/build, icon, and copyright all come from the bundle's
    /// `Info.plist`, so the panel needs no options to populate them — the same
    /// approach as `AppDelegate.showAboutPanel` in the host app. Unlike that
    /// host app (a regular app that's already active), the agent is an
    /// `.accessory` app and isn't active, so it's activated first or the panel
    /// would open behind the frontmost app. A pending update is surfaced as the
    /// credits line so it's visible whether the user opened the menu or About.
    @objc private func aboutTapped() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if case .updateAvailable(let bundled) = updateState() {
            options[.credits] = NSAttributedString(
                string: GuestAgentMenuText.updateAvailableLine(bundled: bundled))
        }
        #if DEBUG
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        options[.version] = buildNumber.isEmpty ? "Debug" : "\(buildNumber) | Debug"
        #endif
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    // MARK: - Helpers

    /// Live update state: compares the agent's own version against the version
    /// the host currently bundles (pulled fresh through the closure).
    private func updateState() -> KernovaVersionComparison.UpdateState {
        KernovaVersionComparison.updateState(own: version, hostBundled: hostBundledVersion())
    }

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
