import AppKit
import KernovaKit
import os

/// Owns the resident agent's menu-bar `NSStatusItem` and its dropdown.
///
/// Present for the whole life of the background-agent process — the always-visible
/// "Kernova is running" affordance, and the discoverable way to summon the GUI
/// when the app is headless (`.accessory`, no Dock icon). The dropdown leads with
/// "Open Kernova" (the library), lists the VMs running headless (click one to
/// open just that VM — its own pop-out/fullscreen display window when that's its
/// preference, else the library selected on it; see
/// `AppDelegate.statusItemOpenTarget`), and ends with Quit; it is rebuilt from
/// live view-model state each time it opens. A live tooltip reflects the running
/// count. Mirrors the guest agent's `AgentStatusItemController`.
///
/// Also surfaces a proactive "enable File Provider" reminder (#581): while the
/// host "Copy to Mac" domain is registered but the user hasn't flipped the
/// System-Settings toggle (`HostClipboardFileProvider.shared.availability ==
/// .needsEnabling`), the icon gets a small attention badge and the dropdown
/// gains an explanatory line, an "Enable in System Settings…" command, and a
/// "Stop Reminding Me" command that silences just the badge — the passive
/// affordances (the clipboard window's `ClipboardEnablementBanner`, this same
/// menu line) stay regardless of dismissal. A registration/install failure
/// (`.unavailable`, #591) badges the icon too, with its own non-dismissible
/// explanatory line (no toggle to flip, so no enable/stop commands).
///
/// While a guest→host paste is materializing through the File Provider it also
/// carries that paste's progress (#643): a determinate ring around the icon, a
/// live readout at the top of the dropdown, and a one-time automatic open of the
/// dropdown so the readout is seen without a click. Finder's copy dialog has
/// never been observed rendering determinate progress for our pulls
/// (docs/CLIPBOARD.md §13), so this is the only surface a multi-GB paste has
/// while it runs. Mirrored by the guest agent's `AgentStatusItemController` for
/// the host→guest direction.
@MainActor
final class HostAgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "app.kernova", category: "HostAgentStatusItem")
    private static let iconSymbol = "macwindow"

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let viewModel: VMLibraryViewModel
    private let preferences: AppPreferences
    /// Summons the GUI. `nil` opens the library; a VM id selects that VM and
    /// opens just it — its own display window or the library, per
    /// `AppDelegate.statusItemOpenTarget`.
    private let onOpen: (UUID?) -> Void
    private let onQuit: () -> Void

    /// Keeps the tooltip in sync with how many VMs are running headless.
    private var runningObservation: ObservationLoop?
    /// Keeps the icon/tooltip in sync with the host File Provider toggle.
    private var fileProviderObservation: ObservationLoop?
    /// Keeps the paste readout in sync with the materializing transfer (#643).
    private var pasteProgressObservation: ObservationLoop?

    /// The paste currently materializing, or `nil` when none is.
    private var pasteProgress: PasteMaterializationSnapshot?
    /// The dropdown's live readout.
    ///
    /// Built on first use — most sessions never paste a file large enough to
    /// reveal one — and then kept, so it updates in place while the dropdown is
    /// open instead of being rebuilt under the cursor.
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
    /// Whether the dropdown is currently on screen, which the auto-opener needs
    /// and `NSMenu` doesn't expose.
    private var menuIsOpen = false
    /// Set between asking for an automatic open and the resulting
    /// `menuWillOpen`, so the opener can tell its own dropdown from one the user
    /// summoned.
    private var pendingAutoOpen = false

    /// Manages the transient "still running in the menu bar" soft-quit reminder
    /// popover (#624).
    private let softQuitReminder = PopoverPresenter()
    /// Auto-dismiss timer for the soft-quit reminder; cancelled if it closes
    /// earlier (opt-out tap, opening the status menu, or a second soft quit).
    private var softQuitReminderDismissTask: Task<Void, Never>?

    init(
        viewModel: VMLibraryViewModel,
        preferences: AppPreferences = .shared,
        onOpen: @escaping (UUID?) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.viewModel = viewModel
        self.preferences = preferences
        self.onOpen = onOpen
        self.onQuit = onQuit
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        setIcon()
        updateTooltip()

        // Refresh the tooltip as VMs start/stop, so the at-a-glance running count
        // stays current even while the menu is closed.
        runningObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                for instance in self.viewModel.instances { _ = instance.isKeepingAppAlive }
            },
            apply: { [weak self] in self?.updateTooltip() }
        )

        // Keeps the badge live as the System-Settings toggle changes — the
        // domain-change observer inside `FileProviderDomainHost` reacts
        // instantly, so this needs no polling.
        fileProviderObservation = observeRecurring(
            track: { _ = HostClipboardFileProvider.shared.availability },
            apply: { [weak self] in self?.fileProviderAvailabilityChanged() }
        )

        // The coordinator publishes an aggregate readout per paste, already
        // rate-bounded by the shared fetch-progress throttle, so this drives the
        // ring and the dropdown row directly without any pacing of its own.
        pasteProgressObservation = observeRecurring(
            track: { _ = HostClipboardFileProvider.shared.materializationProgress },
            apply: { [weak self] in self?.pasteProgressChanged() }
        )
    }

    // MARK: - Paste progress (#643)

    /// Applies the current paste readout to the icon, the dropdown, and the
    /// tooltip.
    private func pasteProgressChanged() {
        let snapshot = HostClipboardFileProvider.shared.materializationProgress
        pasteProgress = snapshot
        if let snapshot { pasteProgressView.apply(snapshot) }
        setIcon()
        updateTooltip()
        syncPasteProgressItems()
        applyPasteAutoOpen(hasReadout: snapshot != nil)
    }

    /// Adds or removes the readout rows from a dropdown that is already on
    /// screen.
    ///
    /// A closed dropdown needs nothing — `menuNeedsUpdate` rebuilds it from
    /// `pasteProgress` when it next opens.
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
        // dropdown popped from a hidden item would appear anchored to nothing —
        // the same degradation the soft-quit reminder takes.
        let canOpen = statusItem.isVisible && statusItem.button?.window != nil
        switch pasteAutoOpener.readoutChanged(
            hasReadout: hasReadout, menuIsOpen: menuIsOpen, canOpen: canOpen)
        {
        case .none:
            break
        case .open:
            // A soft-quit reminder detaches the dropdown while it is anchored,
            // so the click below would land on its dismissal handler instead of
            // opening the menu. The reminder has had its moment.
            dismissSoftQuitReminder()
            // Deferred a turn: `performClick` spins a nested menu-tracking loop
            // that doesn't return until the dropdown closes, which would strand
            // this observation callback for the whole paste.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The paste can end inside that turn (a cancel lands as a pull
                // failure); opening for a readout that is already gone would
                // leave a dropdown nothing will close.
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
        case .close:
            menu.cancelTracking()
        }
    }

    // MARK: - Soft-quit reminder (#624)

    /// Shows a transient reminder popover anchored to the status item after a soft
    /// quit — unless the user has silenced it.
    ///
    /// Shown on every soft quit until "Stop Reminding Me". A second soft quit
    /// while one is still up reuses the slot (`PopoverPresenter` refreshes in
    /// place) and re-arms the auto-dismiss timer.
    ///
    /// Skipped when the status item isn't on screen: macOS hides status items it
    /// can't fit in a crowded menu bar, and a popover anchored to a hidden button
    /// would point at nothing. The reminder is a nicety, so dropping it is the
    /// right degradation — the app stays reachable through the item once the user
    /// makes room (or via Finder/Dock reopen).
    func showSoftQuitReminder() {
        guard !preferences.menuBarQuitReminderDismissed else { return }
        guard let button = statusItem.button, statusItem.isVisible, button.window != nil else {
            Self.logger.info(
                "Soft-quit reminder skipped — the status item is not currently on screen")
            return
        }

        // Re-arm cleanly if a prior reminder is still up.
        softQuitReminderDismissTask?.cancel()

        // RATIONALE: detach the dropdown while the reminder popover is anchored.
        // With `statusItem.menu` assigned, `NSPopover.show(relativeTo:)` against
        // the status-item button pops the assigned menu open by itself (macOS 26,
        // observed on every soft quit with a cursor nowhere near the item), and
        // the menu open then dismisses the reminder via `menuNeedsUpdate` within
        // a frame — the popover flashed and vanished. Every dismissal path
        // restores the menu (`dismissSoftQuitReminder`); while the reminder is
        // up, a click on the item lands on the temporary button action below,
        // which dismisses the reminder and reopens the dropdown the user asked
        // for.
        statusItem.menu = nil
        button.target = self
        button.action = #selector(statusItemTappedDuringReminder)

        let content = MenuBarQuitReminderViewController(onStopReminding: { [weak self] in
            guard let self else { return }
            self.preferences.menuBarQuitReminderDismissed = true
            Self.logger.info("Soft-quit menu-bar reminder silenced by the user")
            self.dismissSoftQuitReminder()
        })
        // Anchored below the icon (menu bar sits at the top of the screen).
        // RATIONALE: `.applicationDefined`, not the default `.transient` — a soft
        // quit deactivates the app moments after this shows (the GUI windows
        // close and the activation-policy reconcile drops to `.accessory`), and a
        // `.transient` popover auto-closes on app deactivation (see
        // `PopoverPresenter`'s `onClose` doc), so the reminder would flash and
        // vanish before the user could read it. Lifetime is bounded instead by
        // the auto-dismiss timer below, the opt-out tap, and a click on the
        // status item — which, since the dropdown is detached above, lands on
        // `statusItemTappedDuringReminder` rather than opening the menu — at
        // which point the reminder has done its job.
        softQuitReminder.show(
            content: content, from: button, preferredEdge: .minY, behavior: .applicationDefined)
        Self.logger.debug("Showing soft-quit menu-bar reminder")

        // One-shot auto-dismiss timer — `Task.sleep` is the delay itself; with
        // the `.applicationDefined` popover this is the primary bound on how
        // long an ignored reminder lingers.
        softQuitReminderDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            self?.dismissSoftQuitReminder()
        }
    }

    /// Closes the soft-quit reminder, cancels its auto-dismiss timer, and
    /// reattaches the dropdown the reminder had detached.
    ///
    /// Idempotent.
    private func dismissSoftQuitReminder() {
        softQuitReminderDismissTask?.cancel()
        softQuitReminderDismissTask = nil
        softQuitReminder.close()
        reattachStatusItemMenu()
    }

    /// Restores the dropdown after the soft-quit reminder detached it, clearing
    /// the temporary button action.
    ///
    /// Idempotent (no-op when the menu is already attached).
    private func reattachStatusItemMenu() {
        guard statusItem.menu == nil else { return }
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusItem.menu = menu
    }

    /// A click on the status item while the soft-quit reminder is up (and the
    /// dropdown is therefore detached): the reminder has done its job, so
    /// dismiss it and open the dropdown the click asked for.
    @objc private func statusItemTappedDuringReminder() {
        dismissSoftQuitReminder()
        // Deferred a tick: `dismissSoftQuitReminder` reattached the menu, but
        // popping it from inside the button-action callback that the same click
        // is still delivering re-enters menu tracking mid-event; the next
        // runloop turn opens it cleanly.
        Task { @MainActor [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    // MARK: - File Provider reminder

    /// Whether the proactive status-item badge should currently show.
    ///
    /// Distinct from the always-present passive menu line below, which shows
    /// whenever the toggle is off regardless of dismissal. Covers both the
    /// dismissible `.needsEnabling` nudge and the non-dismissible
    /// `.unavailable` failure badge (#591) — see `ClipboardFileProviderReminder
    /// .shouldShowBadge`.
    private var reminderActive: Bool {
        ClipboardFileProviderReminder.shouldShowBadge(
            availability: HostClipboardFileProvider.shared.availability,
            dismissed: preferences.fileProviderReminderDismissed)
    }

    private func fileProviderAvailabilityChanged() {
        preferences.fileProviderReminderDismissed =
            ClipboardFileProviderReminder
            .dismissalAfterAvailabilityChange(
                HostClipboardFileProvider.shared.availability,
                dismissed: preferences.fileProviderReminderDismissed)
        setIcon()
        updateTooltip()
    }

    // MARK: - Icon / tooltip

    private func setIcon() {
        // RATIONALE: deliberately not the shared `NSImage.systemSymbol(_:…)` helper.
        // Its release fallback is a zero-size `NSImage()`, which would render the
        // status-item button invisible — and the status item is the *only* way to
        // find (or quit) the headless agent. This hand-rolled guard degrades to a
        // visible "K" title instead, so the affordance never disappears.
        guard
            let image = NSImage(
                systemSymbolName: Self.iconSymbol, accessibilityDescription: "Kernova")
        else {
            // The SF Symbol name is a compile-time constant; a miss is a typo or a
            // deployment-target mismatch. Crash in debug, degrade to a glyph in release.
            Self.logger.fault(
                "Missing SF Symbol '\(Self.iconSymbol, privacy: .public)' for status item")
            assertionFailure("Missing SF Symbol '\(Self.iconSymbol)'")
            statusItem.button?.title = "K"
            return
        }
        image.isTemplate = true
        // A materializing paste outranks the enablement badge: it is happening
        // right now and ends on its own, while the badge is a standing nudge
        // that will still be there afterwards. In practice the two barely
        // overlap — a paste only materializes through the File Provider while
        // the domain is `.ready`, which is exactly when the badge is absent —
        // so this only decides the moment a user flips the toggle off mid-paste.
        if let pasteProgress {
            statusItem.button?.image = image.withProgressRing(
                fraction: pasteProgress.fractionComplete)
            return
        }
        statusItem.button?.image = reminderActive ? image.withAttentionBadge() : image
    }

    /// Updates the tooltip.
    ///
    /// The running-count line always shows (the class's
    /// own promise); a materializing paste (#643) and the reminder — when
    /// active — append as further lines rather than replacing it, so headless
    /// users don't lose the only at-a-glance view of how many VMs are running
    /// (#581).
    private func updateTooltip() {
        let count = viewModel.instances.lazy.filter(\.isKeepingAppAlive).count
        var lines: [String]
        switch count {
        case 0: lines = ["Kernova"]
        case 1: lines = ["Kernova — 1 virtual machine running"]
        default: lines = ["Kernova — \(count) virtual machines running"]
        }
        if let pasteProgress { lines.append(PasteProgressFormat.summary(pasteProgress)) }
        if reminderActive { lines.append(badgeSummary()) }
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    /// The badge tooltip's second line for the current availability, picking
    /// the distinct `.unavailable` (#591) copy over the routine
    /// `.needsEnabling` (#581) copy so an install/signing problem reads
    /// differently from "flip this toggle".
    private func badgeSummary() -> String {
        HostClipboardFileProvider.shared.availability == .unavailable
            ? ClipboardFileProviderReminder.hostUnavailableSummary()
            : ClipboardFileProviderReminder.hostDegradedSummary()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opening the dropdown means the user found the icon — the soft-quit
        // reminder (which the `.applicationDefined` popover would otherwise keep
        // up until its timer) has done its job.
        dismissSoftQuitReminder()

        menu.removeAllItems()

        // A materializing paste leads: it is the only transient thing here, and
        // the automatic open exists to put it in front of the user (#643).
        if pasteProgress != nil { insertPasteProgressItems() }

        let open = NSMenuItem(title: "Open Kernova", action: #selector(openTapped), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        // Passive affordance: shown whenever the toggle is off, independent of
        // whether the proactive badge reminder was dismissed (#581).
        let availability = HostClipboardFileProvider.shared.availability
        if availability == .needsEnabling {
            addInfoItem(ClipboardFileProviderReminder.hostDegradedSummary())

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
            addInfoItem(ClipboardFileProviderReminder.hostUnavailableSummary())
            menu.addItem(.separator())
        }

        let running = viewModel.instances.filter(\.isKeepingAppAlive)
        if running.isEmpty {
            let none = NSMenuItem(
                title: "No virtual machines running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for instance in running {
                let item = NSMenuItem(
                    title: "\(instance.name) — \(instance.status.displayName)",
                    action: #selector(openVMTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = instance.instanceID
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Kernova", action: #selector(quitTapped), keyEquivalent: "")
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

    /// Appends a disabled, informational (non-actionable) line to the dropdown.
    private func addInfoItem(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func openTapped() { onOpen(nil) }

    @objc private func openVMTapped(_ sender: NSMenuItem) {
        onOpen(sender.representedObject as? UUID)
    }

    @objc private func quitTapped() { onQuit() }

    /// Opens System Settings so the user can enable the host File Provider
    /// (see `ClipboardFileProviderSettings.openEnablementSettings()`).
    @objc private func enableFileSharingTapped() {
        if !ClipboardFileProviderSettings.openEnablementSettings() {
            Self.logger.error("Failed to open File Providers settings deep link")
        }
    }

    @objc private func stopRemindingTapped() {
        preferences.fileProviderReminderDismissed = true
        setIcon()
        updateTooltip()
    }
}
