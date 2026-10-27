import AppKit
import KernovaAppKitShared
import KernovaKit
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

    private let version: String
    private let connectionState: () -> HostConnectionState
    private let hostBundledVersion: () -> String
    private let logForwardingEnabled: () -> Bool
    private let clipboardActivity: () -> ClipboardActivity
    private let onCancelTransfer: (ClipboardTransferOperationID) -> Void
    private let onQuit: () -> Void

    /// Whether the dropdown is currently on screen, which `NSMenu` doesn't
    /// expose.
    private var isMenuOpen = false

    /// The status item's one popover slot, shared by the transfer readout's
    /// callout and the clipboard notice.
    private lazy var calloutSlot = TransientStatusItemPopover(
        statusItem: statusItem, menu: menu,
        isDropdownOpen: { [weak self] in self?.isMenuOpen ?? false })

    /// Built lazily, since most sessions never reveal a paste readout.
    private lazy var pasteProgressPresenter = ClipboardProgressStatusItemPresenter(
        menu: menu, slot: calloutSlot,
        onCancel: { [weak self] id in self?.onCancelTransfer(id) })

    /// How long a clipboard notice stays up unattended.
    private static let clipboardNoticeDuration: TimeInterval = 6

    init(
        version: String,
        connectionState: @escaping () -> HostConnectionState,
        hostBundledVersion: @escaping () -> String,
        logForwardingEnabled: @escaping () -> Bool,
        clipboardActivity: @escaping () -> ClipboardActivity,
        onCancelTransfer: @escaping (ClipboardTransferOperationID) -> Void = { _ in },
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.version = version
        self.connectionState = connectionState
        self.hostBundledVersion = hostBundledVersion
        self.logForwardingEnabled = logForwardingEnabled
        self.clipboardActivity = clipboardActivity
        self.onCancelTransfer = onCancelTransfer
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
    /// Takes no state: `onStateChange` deliveries are hopped to main through
    /// independently spawned tasks with no ordering guarantee, so the live
    /// lock-guarded state is re-read instead of trusting a delivered value.
    func connectionStateChanged() {
        setIcon(for: connectionState())
    }

    // MARK: - Paste progress

    /// Applies the transfer report this agent's reporter just published.
    func transferReportChanged(_ report: ClipboardTransferReport) {
        pasteProgressPresenter.apply(report)
        setIcon(for: connectionState())
    }

    // MARK: - Clipboard notice

    /// Shows the clipboard notice the agent just recorded as a callout on the
    /// status item.
    ///
    /// The notice ends a gesture the user made in this guest and produces no
    /// other signal — the paste simply yields nothing, the copy simply crosses
    /// short — so the line is shown rather than left for whenever the menu is
    /// next opened. The dropdown keeps the same line, which is the fallback when
    /// the status item can't carry the callout.
    func clipboardNoticeRaised() {
        let activity = clipboardActivity()
        // Delivered asynchronously, so a later activity may already have
        // replaced the notice.
        guard activity.isNotice else { return }
        let content = AgentClipboardNoticeViewController(line: AgentMenuText.clipboardLine(activity))
        if case .skipped(let reason) = calloutSlot.show(content, for: Self.clipboardNoticeDuration) {
            Self.logger.log(
                .info, "Clipboard notice skipped — \(String(describing: reason), privacy: .public)")
            return
        }
        Self.logger.log(.info, "Showing a clipboard notice")
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
        if let snapshot = pasteProgressPresenter.snapshot {
            statusItem.button?.image = image.withProgressRing(
                fraction: snapshot.fractionComplete)
            statusItem.button?.toolTip = ClipboardProgressFormat.summary(snapshot)
            return
        }
        statusItem.button?.image = image
        statusItem.button?.toolTip = nil
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opening the dropdown means the user came looking — the notice's line
        // and the readout are in the menu below.
        calloutSlot.dismiss()

        menu.removeAllItems()

        pasteProgressPresenter.insertItemsIfActive()

        if case .updateAvailable(let bundled) = updateState() {
            addInfoItem(AgentMenuText.updateAvailableLine(bundled: bundled))
            menu.addItem(.separator())
        }

        let activity = clipboardActivity()
        // A notice is what the callout announced, so it reads at the top level;
        // every other activity is state the Status submenu holds.
        if activity.isNotice {
            addInfoItem(AgentMenuText.clipboardLine(activity))
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
        if case .updateAvailable(let bundled) = updateState() {
            options[.credits] = NSAttributedString(
                string: AgentMenuText.updateAvailableLine(bundled: bundled))
        }
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

    private func updateState() -> KernovaVersionComparison.UpdateState {
        KernovaVersionComparison.updateState(own: version, hostBundled: hostBundledVersion())
    }

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
