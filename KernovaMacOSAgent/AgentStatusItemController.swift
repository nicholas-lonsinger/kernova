import AppKit
import KernovaAgentCore
import KernovaAppKitShared
import KernovaLogging

/// Owns the agent's menu-bar `NSStatusItem` and its dropdown.
///
/// Clipboard and log enablement are host-driven, so the menu reflects state
/// rather than offering switches that would fight host policy. Dynamic lines are
/// rebuilt on `menuNeedsUpdate` from the closures supplied at init; the icon is
/// updated live so it tracks state while the menu is closed.
@MainActor
final class AgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "AgentStatusItem")

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let connectionState: () -> HostConnectionState
    private let logForwardingEnabled: () -> Bool
    private let clipboardActivity: () -> ClipboardActivity
    /// The clipboard notice that stands, if any.
    private let clipboardNotice: () -> ClipboardActivity?
    private let onQuit: () -> Void

    /// Whether the dropdown is currently on screen, which `NSMenu` doesn't
    /// expose.
    private var isMenuOpen = false

    /// The status item's popover slot, which carries the clipboard notice.
    private lazy var calloutSlot = TransientStatusItemPopover(
        statusItem: statusItem, menu: menu,
        isDropdownOpen: { [weak self] in self?.isMenuOpen ?? false })

    init(
        connectionState: @escaping () -> HostConnectionState,
        logForwardingEnabled: @escaping () -> Bool,
        clipboardActivity: @escaping () -> ClipboardActivity,
        clipboardNotice: @escaping () -> ClipboardActivity?,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.connectionState = connectionState
        self.logForwardingEnabled = logForwardingEnabled
        self.clipboardActivity = clipboardActivity
        self.clipboardNotice = clipboardNotice
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
    /// Takes no state: each change is hopped to main through its own task, with
    /// no ordering guarantee, so the current state is re-read instead.
    func connectionStateChanged() {
        setIcon(for: connectionState())
    }

    // MARK: - Clipboard notice

    /// Shows the clipboard notice the agent just recorded as a callout on the
    /// status item.
    ///
    /// The notice ends a gesture the user made in this guest and produces no
    /// other signal — the paste simply yields nothing, the copy simply crosses
    /// short — so the line is shown rather than left for whenever the menu is
    /// next opened, as an error: up until the user clicks it or the status
    /// item, or the notice stops standing. The dropdown keeps the same line
    /// while it stands, which is the fallback when the status item can't carry
    /// the callout.
    func clipboardNoticeRaised() {
        // Delivered asynchronously, so a later activity may already have
        // ended the notice.
        guard let notice = clipboardNotice() else { return }
        let line = AgentMenuText.clipboardLine(notice)
        let content = AgentClipboardNoticeViewController(line: line)
        let lifetime = CalloutLifetime.error(
            announcement: line, stands: { [weak self] in self?.clipboardNotice() == notice })
        if case .skipped(let reason) = calloutSlot.show(content, as: lifetime) {
            Self.logger.log(
                .info, "Clipboard notice skipped — \(String(describing: reason), privacy: .public)")
            return
        }
        Self.logger.log(.info, "Showing a clipboard notice")
    }

    /// The clipboard's activity changed: a notice up that no longer stands
    /// goes.
    func clipboardActivityChanged() {
        calloutSlot.failuresChanged()
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
            Self.logger.log(.fault, "Missing SF Symbol '\(name, privacy: .public)' for status item")
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
        // Opening the dropdown means the user came looking — the notice's line
        // is in the menu below.
        calloutSlot.dismiss()

        menu.removeAllItems()

        let activity = clipboardActivity()
        // A notice is what the callout announced, so it reads at the top level
        // while it stands; the latest activity is state the Status submenu
        // holds.
        if let notice = clipboardNotice() {
            addInfoItem(AgentMenuText.clipboardLine(notice))
            menu.addItem(.separator())
        }

        addInfoItem(AgentMenuText.hostStatusLine(connectionState()))

        let statusMenuItem = NSMenuItem(
            title: AgentMenuText.statusSubmenu(), action: nil, keyEquivalent: "")
        let statusMenu = NSMenu()
        statusMenu.autoenablesItems = false
        addInfoItem(AgentMenuText.logForwardingLine(logForwardingEnabled()), to: statusMenu)
        addInfoItem(AgentMenuText.clipboardLine(activity), to: statusMenu)
        statusMenuItem.submenu = statusMenu
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: AgentMenuText.about(), action: #selector(aboutTapped), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(
            title: AgentMenuText.quit(), action: #selector(quitTapped), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    // MARK: - About

    /// Opens the standard AppKit About panel.
    ///
    /// The agent is an `.accessory` app and is never already active, so it must
    /// be activated first or the panel opens behind the frontmost app.
    @objc private func aboutTapped() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        #if DEBUG
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        options[.version] = buildNumber.isEmpty ? "Debug" : "\(buildNumber) | Debug"
        #endif
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    // MARK: - Helpers

    /// Appends a disabled, non-actionable line to `destination`, defaulting to
    /// the main dropdown.
    private func addInfoItem(_ title: String, to destination: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        (destination ?? menu).addItem(item)
    }

    @objc private func quitTapped() {
        onQuit()
    }
}
