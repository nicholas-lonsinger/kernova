import AppKit
import KernovaKit
import os

/// Owns the agent's menu-bar `NSStatusItem` and its dropdown.
///
/// Clipboard and log enablement are host-driven, so the menu reflects state
/// rather than offering switches that would fight host policy. Dynamic lines are
/// rebuilt on `menuNeedsUpdate` from the closures supplied at init; the icon is
/// updated live so it tracks state while the menu is closed.
@MainActor
final class AgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "app.kernova.macosagent", category: "AgentStatusItem")

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let version: String
    private let connectionState: () -> HostConnectionState
    private let hostBundledVersion: () -> String
    private let logForwardingEnabled: () -> Bool
    private let clipboardActivity: () -> ClipboardActivity
    private let onQuit: () -> Void

    /// Built lazily, since most sessions never reveal a paste readout.
    private lazy var pasteProgressPresenter = ClipboardProgressStatusItemPresenter(
        statusItem: statusItem, menu: menu)

    init(
        version: String,
        connectionState: @escaping () -> HostConnectionState,
        hostBundledVersion: @escaping () -> String,
        logForwardingEnabled: @escaping () -> Bool,
        clipboardActivity: @escaping () -> ClipboardActivity,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.version = version
        self.connectionState = connectionState
        self.hostBundledVersion = hostBundledVersion
        self.logForwardingEnabled = logForwardingEnabled
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
    /// Takes no state deliberately: `onStateChange` deliveries are hopped to main
    /// through independently spawned tasks with no ordering guarantee, so the
    /// live lock-guarded state is re-read instead of trusting a delivered value.
    func connectionStateChanged() {
        setIcon(for: connectionState())
    }

    // MARK: - Paste progress

    /// Applies the paste readout the clipboard agent's progress tracker just
    /// published — a snapshot to render, or `nil` to clear it.
    func materializationProgressChanged(_ snapshot: ClipboardProgressSnapshot?) {
        pasteProgressPresenter.apply(snapshot)
        setIcon(for: connectionState())
    }

    // MARK: - Clipboard notice

    /// Opens the dropdown on the clipboard refusal the agent just recorded.
    ///
    /// The refusal ends a gesture the user made in this guest and produces no
    /// other signal — the paste simply yields nothing — so the line is revealed
    /// rather than left for whenever the menu is next opened.
    func clipboardNoticeRaised() {
        // macOS drops status items it can't fit in a crowded menu bar.
        guard statusItem.isVisible, statusItem.button?.window != nil else { return }
        // Never defer this with `Task { @MainActor }`: `performClick` parks inside
        // a nested menu-tracking loop until the dropdown closes, and parking there
        // from a main-queue block starves every later main-queue update.
        performOnMainRunLoop { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
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
            Self.logger.fault("Missing SF Symbol '\(name, privacy: .public)' for status item")
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
        menu.removeAllItems()

        pasteProgressPresenter.insertItemsIfActive()

        if case .updateAvailable(let bundled) = updateState() {
            addInfoItem(AgentMenuText.updateAvailableLine(bundled: bundled))
            menu.addItem(.separator())
        }

        let activity = clipboardActivity()
        // A refusal is what the auto-open is revealing, so it reads at the top
        // level; every other activity is state the Status submenu holds.
        if activity == .pasteRefusedTooLarge {
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
        pasteProgressPresenter.menuWillOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        pasteProgressPresenter.menuDidClose()
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
        NSApp.activate()
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
