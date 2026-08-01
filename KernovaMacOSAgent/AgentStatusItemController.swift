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
    private let preferences: AgentPreferences
    private let connectionState: () -> HostConnectionState
    private let hostBundledVersion: () -> String
    private let logForwardingEnabled: () -> Bool
    private let clipboardActivity: () -> ClipboardActivity
    private let fileProviderAvailability: () -> FileProviderAvailability
    private let onQuit: () -> Void

    /// Built lazily, since most sessions never reveal a paste readout.
    private lazy var pasteProgressPresenter = ClipboardProgressStatusItemPresenter(
        statusItem: statusItem, menu: menu)

    init(
        version: String,
        preferences: AgentPreferences = .shared,
        connectionState: @escaping () -> HostConnectionState,
        hostBundledVersion: @escaping () -> String,
        logForwardingEnabled: @escaping () -> Bool,
        clipboardActivity: @escaping () -> ClipboardActivity,
        fileProviderAvailability: @escaping () -> FileProviderAvailability,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.version = version
        self.preferences = preferences
        self.connectionState = connectionState
        self.hostBundledVersion = hostBundledVersion
        self.logForwardingEnabled = logForwardingEnabled
        self.clipboardActivity = clipboardActivity
        self.fileProviderAvailability = fileProviderAvailability
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

    /// Updates the menu-bar icon, and resets a stale dismissal, for a File
    /// Provider availability change.
    ///
    /// Delivered synchronously on main, so `availability` is trusted directly
    /// rather than re-read.
    func fileProviderAvailabilityChanged(_ availability: FileProviderAvailability) {
        preferences.fileProviderReminderDismissed =
            ClipboardFileProviderReminder
            .dismissalAfterAvailabilityChange(
                availability, dismissed: preferences.fileProviderReminderDismissed)
        setIcon(for: connectionState())
    }

    // MARK: - Paste progress

    /// Applies the paste readout the domain host just published — a snapshot to
    /// render, or `nil` to clear it.
    func materializationProgressChanged(_ snapshot: ClipboardProgressSnapshot?) {
        pasteProgressPresenter.apply(snapshot)
        setIcon(for: connectionState())
    }

    /// Whether the proactive status-item badge should currently show.
    ///
    /// Distinct from the passive menu line, which shows whenever the toggle is
    /// off regardless of dismissal.
    private var reminderActive: Bool {
        ClipboardFileProviderReminder.shouldShowBadge(
            availability: fileProviderAvailability(),
            dismissed: preferences.fileProviderReminderDismissed)
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
        // A materializing paste outranks the standing enablement badge.
        if let snapshot = pasteProgressPresenter.snapshot {
            statusItem.button?.image = image.withProgressRing(
                fraction: snapshot.fractionComplete)
            statusItem.button?.toolTip = ClipboardProgressFormat.summary(snapshot)
            return
        }
        statusItem.button?.image = reminderActive ? image.withAttentionBadge() : image
        statusItem.button?.toolTip = reminderActive ? badgeSummary() : nil
    }

    private func badgeSummary() -> String {
        fileProviderAvailability() == .unavailable
            ? ClipboardFileProviderReminder.guestUnavailableSummary()
            : ClipboardFileProviderReminder.guestDegradedSummary()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        pasteProgressPresenter.insertItemsIfActive()

        if case .updateAvailable(let bundled) = updateState() {
            addInfoItem(AgentMenuText.updateAvailableLine(bundled: bundled))
            menu.addItem(.separator())
        }

        let availability = fileProviderAvailability()
        // `.needsEnabling` is the one File-Provider state the user must act on;
        // this line shows regardless of whether the badge reminder was dismissed.
        if availability == .needsEnabling {
            addInfoItem(ClipboardFileProviderReminder.guestDegradedSummary())
            let enable = NSMenuItem(
                title: ClipboardFileProviderReminder.enableCommandTitle(),
                action: #selector(enableFileSharingTapped), keyEquivalent: "")
            enable.target = self
            menu.addItem(enable)
            if ClipboardFileProviderReminder.shouldShowReminder(
                availability: availability, dismissed: preferences.fileProviderReminderDismissed)
            {
                let stop = NSMenuItem(
                    title: ClipboardFileProviderReminder.stopRemindingCommandTitle(),
                    action: #selector(stopRemindingTapped), keyEquivalent: "")
                stop.target = self
                menu.addItem(stop)
            }
            menu.addItem(.separator())
        } else if availability == .unavailable {
            // A registration failure has no toggle to flip, so no commands.
            addInfoItem(ClipboardFileProviderReminder.guestUnavailableSummary())
            menu.addItem(.separator())
        }

        addInfoItem(AgentMenuText.hostStatusLine(connectionState()))

        let statusMenuItem = NSMenuItem(
            title: AgentMenuText.statusSubmenu(), action: nil, keyEquivalent: "")
        let statusMenu = NSMenu()
        statusMenu.autoenablesItems = false
        addInfoItem(AgentMenuText.logForwardingLine(logForwardingEnabled()), to: statusMenu)
        addInfoItem(AgentMenuText.clipboardLine(clipboardActivity()), to: statusMenu)
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

    @objc private func enableFileSharingTapped() {
        if !ClipboardFileProviderSettings.openEnablementSettings() {
            Self.logger.error("Failed to open File Providers settings deep link")
        }
    }

    /// Silences the badge reminder for the current episode; the dropdown line and
    /// enable command stay.
    @objc private func stopRemindingTapped() {
        preferences.fileProviderReminderDismissed = true
        setIcon(for: connectionState())
    }
}
