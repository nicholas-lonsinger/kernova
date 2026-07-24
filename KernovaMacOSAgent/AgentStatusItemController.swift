import AppKit
import KernovaKit
import os

/// Owns the agent's menu-bar `NSStatusItem` and its dropdown.
///
/// The dropdown leads with the live host-connection line, then a "Status"
/// submenu grouping the two host-driven capability states (log forwarding,
/// clipboard), and offers About + Quit: clipboard/log enablement is host-driven
/// (the host pushes `PolicyUpdate`), so the menu reflects state rather than
/// offering switches that would fight host policy. Identity, version/build, and
/// copyright live in the standard About panel (`aboutTapped`); a pending agent
/// update also surfaces as a top-level hint line. Dynamic lines are rebuilt
/// each time the menu opens (`menuNeedsUpdate`) by pulling the current state
/// through the closures supplied at init; the status-item icon is updated live
/// via `connectionStateChanged()` so it tracks the connection even while the
/// menu is closed.
///
/// Also surfaces a proactive "enable File Provider" reminder (#581): while the
/// guest clipboard domain is registered but the user hasn't flipped the
/// System-Settings toggle (`fileProviderAvailability() == .needsEnabling`),
/// the icon gets a small attention badge and the dropdown gains a "Stop
/// Reminding Me" command that silences just the badge — the passive
/// explanatory line + "Enable in System Settings…" command stay regardless of
/// dismissal. A registration/install failure (`.unavailable`, #591) badges the
/// icon too, with its own non-dismissible explanatory line (no toggle to
/// flip, so no enable/stop commands). Mirrors the host app's
/// `HostAgentStatusItemController`.
///
/// While a host→guest paste is materializing through the File Provider it also
/// carries that paste's progress (#643): a determinate ring around the icon, a
/// live readout at the top of the dropdown, and a one-time automatic open of the
/// dropdown. Rendering it here rather than on the host is deliberate — the user
/// who pressed ⌘V is looking at the guest's screen, and this status item is the
/// agent's only UI.
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

    /// The paste currently materializing into the guest, or `nil` when none is
    /// (#643).
    private var pasteProgress: PasteMaterializationSnapshot?
    /// The dropdown's live readout, built on first use and then kept so it
    /// updates in place while the dropdown is open.
    private lazy var pasteProgressView = PasteProgressMenuItemView()
    private lazy var pasteProgressItem: NSMenuItem = {
        let item = NSMenuItem()
        item.view = pasteProgressView
        item.isEnabled = false
        return item
    }()
    private let pasteProgressSeparator = NSMenuItem.separator()
    /// Decides when the readout opens and closes the dropdown by itself.
    private var pasteAutoOpener = PasteProgressMenuAutoOpener()
    /// Whether the dropdown is currently on screen, which `NSMenu` doesn't
    /// expose and the auto-opener needs.
    private var menuIsOpen = false
    /// Set between asking for an automatic open and the resulting
    /// `menuWillOpen`, so the opener can tell its own dropdown from one the user
    /// summoned.
    private var pendingAutoOpen = false

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

    /// Updates the menu-bar icon (and resets a stale dismissal) to reflect a
    /// File Provider availability change (#581).
    ///
    /// Called by the app delegate from `FileProviderDomainHost
    /// .setAvailabilityObserver`, which — unlike `onStateChange` above —
    /// delivers synchronously on main, so `availability` is trusted directly
    /// rather than re-read.
    func fileProviderAvailabilityChanged(_ availability: FileProviderAvailability) {
        preferences.fileProviderReminderDismissed =
            ClipboardFileProviderReminder
            .dismissalAfterAvailabilityChange(
                availability, dismissed: preferences.fileProviderReminderDismissed)
        setIcon(for: connectionState())
    }

    // MARK: - Paste progress (#643)

    /// Applies the paste readout the domain host just published — a snapshot to
    /// render, or `nil` to clear it.
    ///
    /// Called by the app delegate from `FileProviderDomainHost
    /// .setMaterializationObserver`, which delivers on main.
    func materializationProgressChanged(_ snapshot: PasteMaterializationSnapshot?) {
        pasteProgress = snapshot
        if let snapshot { pasteProgressView.apply(snapshot) }
        setIcon(for: connectionState())
        syncPasteProgressItems()
        applyPasteAutoOpen(hasReadout: snapshot != nil)
    }

    /// Adds or removes the readout rows from a dropdown that is already on
    /// screen; a closed one is rebuilt by `menuNeedsUpdate` when it next opens.
    private func syncPasteProgressItems() {
        guard menuIsOpen else { return }
        if pasteProgress != nil {
            insertPasteProgressItems()
        } else {
            removePasteProgressItems()
        }
    }

    private func insertPasteProgressItems() {
        guard menu.index(of: pasteProgressItem) < 0 else { return }
        menu.insertItem(pasteProgressItem, at: 0)
        menu.insertItem(pasteProgressSeparator, at: 1)
    }

    private func removePasteProgressItems() {
        for item in [pasteProgressSeparator, pasteProgressItem] where menu.index(of: item) >= 0 {
            menu.removeItem(item)
        }
    }

    /// Runs the auto-opener's decision for the current readout.
    private func applyPasteAutoOpen(hasReadout: Bool) {
        // macOS drops status items it can't fit in a crowded menu bar, and a
        // dropdown popped from a hidden item would appear anchored to nothing.
        let canOpen = statusItem.isVisible && statusItem.button?.window != nil
        switch pasteAutoOpener.readoutChanged(
            hasReadout: hasReadout, menuIsOpen: menuIsOpen, canOpen: canOpen)
        {
        case .none:
            break
        case .open:
            scheduleDropdownOpen()
        case .close:
            menu.cancelTracking()
        }
    }

    /// Opens the dropdown from a run-loop callout — deferred, and deliberately
    /// NOT via `Task`/`DispatchQueue.main.async`.
    ///
    /// `performClick` spins a nested menu-tracking run loop that does not
    /// return until the dropdown closes. The deferral exists so this callback
    /// isn't stranded inside it for the whole paste — but the *kind* of
    /// deferral is load-bearing: the main queue is serial, so a tracking
    /// session started from inside one of its work items (a `Task` body, a
    /// `main.async` block) can never drain the queue again until the menu
    /// closes, and every later main-actor callout — the domain host's snapshot
    /// hops, `setIcon` — just piles up. Observed live on the host side as
    /// #643's readout and icon ring freezing exactly while the auto-opened
    /// dropdown showed them, then animating fine when the user reopened the
    /// menu themselves (AppKit's own click starts tracking from an event
    /// callout, leaving the queue free). A `RunLoop` block is a run-loop
    /// callout, not a queue item, so the dispatch main-queue source keeps
    /// firing during the tracking it starts — the same situation as a user
    /// click.
    private func scheduleDropdownOpen() {
        RunLoop.main.perform { [weak self] in
            guard let self else { return }
            // The paste can end inside the deferral; opening for a readout that
            // is already gone would leave a dropdown nothing will close.
            guard self.pasteProgress != nil else { return }
            self.pendingAutoOpen = true
            self.statusItem.button?.performClick(nil)
            // `performClick` only returns once the dropdown closes, by which
            // point `menuWillOpen` has consumed the flag. Clearing it here
            // covers the click that opened nothing at all, which would
            // otherwise leave the flag set to mislabel the *user's* next
            // dropdown as ours and close it under them.
            self.pendingAutoOpen = false
        }
    }

    /// Whether the proactive status-item badge should currently show.
    ///
    /// Distinct from the always-present passive menu line below, which shows
    /// whenever the toggle is off regardless of dismissal. Covers both the
    /// dismissible `.needsEnabling` nudge and the non-dismissible
    /// `.unavailable` failure badge (#591) — see `ClipboardFileProviderReminder
    /// .shouldShowBadge`.
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
        // A materializing paste outranks the enablement badge: it is happening
        // now and ends on its own, while the badge is a standing nudge that will
        // still be there afterwards. The two barely overlap in practice — a
        // paste only materializes through the File Provider while the domain is
        // `.ready`, which is exactly when the badge is absent.
        if let pasteProgress {
            statusItem.button?.image = image.withProgressRing(
                fraction: pasteProgress.fractionComplete)
            statusItem.button?.toolTip = PasteProgressFormat.summary(pasteProgress)
            return
        }
        statusItem.button?.image = reminderActive ? image.withAttentionBadge() : image
        statusItem.button?.toolTip = reminderActive ? badgeSummary() : nil
    }

    /// The badge tooltip text for the current availability, picking the
    /// distinct `.unavailable` (#591) copy over the routine `.needsEnabling`
    /// (#581) copy so an install/signing problem reads differently from
    /// "flip this toggle".
    private func badgeSummary() -> String {
        fileProviderAvailability() == .unavailable
            ? ClipboardFileProviderReminder.guestUnavailableSummary()
            : ClipboardFileProviderReminder.guestDegradedSummary()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // A materializing paste leads: it is the only transient thing here, and
        // the automatic open exists to put it in front of the user (#643).
        if pasteProgress != nil { insertPasteProgressItems() }

        // Lead with live status. Identity + version/build are reached through
        // the About item below; only an actionable pending update surfaces here.
        if case .updateAvailable(let bundled) = updateState() {
            addInfoItem(AgentMenuText.updateAvailableLine(bundled: bundled))
            menu.addItem(.separator())
        }

        // Surface an actionable affordance only when the File Provider extension
        // is registered but the user hasn't enabled it (the System-Settings
        // toggle is off), which is the one File-Provider state that needs the
        // user to act before large-file paste reliably works. This passive line
        // shows regardless of whether the proactive badge reminder was
        // dismissed (#581); "Stop Reminding Me" only silences the badge.
        let availability = fileProviderAvailability()
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
            // Registration/install failure (#591) — no user toggle to flip, so
            // no enable/stop commands; the explanatory line is the correction.
            addInfoItem(ClipboardFileProviderReminder.guestUnavailableSummary())
            menu.addItem(.separator())
        }

        addInfoItem(AgentMenuText.hostStatusLine(connectionState()))

        // Group the two host-driven capability states under a "Status" submenu,
        // log forwarding first. The connection line above stays at the top level
        // (it's the headline health and drives the icon).
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
        menuIsOpen = true
        pasteAutoOpener.menuOpened(automatically: pendingAutoOpen)
        pendingAutoOpen = false
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // A user dismissal lands here too, which is what stops a paste from
        // re-opening the dropdown it was just told to go away from.
        pasteAutoOpener.menuClosed()
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

    /// Live update state: compares the agent's own version against the version
    /// the host currently bundles (pulled fresh through the closure).
    private func updateState() -> KernovaVersionComparison.UpdateState {
        KernovaVersionComparison.updateState(own: version, hostBundled: hostBundledVersion())
    }

    /// Appends a disabled, informational (non-actionable) line to `destination`
    /// (the main dropdown by default, or a submenu when one is passed).
    private func addInfoItem(_ title: String, to destination: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        (destination ?? menu).addItem(item)
    }

    @objc private func quitTapped() {
        onQuit()
    }

    /// Opens System Settings so the user can enable the File Provider extension
    /// (see `ClipboardFileProviderSettings.openEnablementSettings()`).
    @objc private func enableFileSharingTapped() {
        if !ClipboardFileProviderSettings.openEnablementSettings() {
            Self.logger.error("Failed to open File Providers settings deep link")
        }
    }

    /// Silences the proactive badge reminder for the current `.needsEnabling`
    /// episode (#581); the passive dropdown line + enable command stay.
    @objc private func stopRemindingTapped() {
        preferences.fileProviderReminderDismissed = true
        setIcon(for: connectionState())
    }
}
