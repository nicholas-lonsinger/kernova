import AppKit
import KernovaKit
import os

/// Owns the resident agent's menu-bar `NSStatusItem` and its dropdown.
///
/// The always-visible "Kernova is running" affordance and the way to summon the
/// GUI when the app is headless (`.accessory`, no Dock icon), so it lives for
/// the whole life of the process. The dropdown is rebuilt from live view-model
/// state each time it opens, and its VM rows are edited in place while it is on
/// screen so the readout tracks starts, stops, and status transitions live.
@MainActor
final class HostAgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "app.kernova", category: "HostAgentStatusItem")
    private static let iconSymbol = "macwindow"

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    /// The dropdown's VM rows, edited in place while the menu is on screen.
    private lazy var vmSection = StatusMenuVMSection(
        menu: menu, rowTarget: self, rowAction: #selector(openVMTapped(_:)))
    /// Whether the dropdown is currently on screen, which `NSMenu` doesn't
    /// expose; gates the live row sync.
    private var isMenuOpen = false

    private let viewModel: VMLibraryViewModel
    private let preferences: AppPreferences
    /// Summons the GUI — `nil` opens the library, a VM id opens just that VM.
    private let onOpen: (UUID?) -> Void
    private let onQuit: () -> Void

    /// Keeps the tooltip — and, while the dropdown is open, its VM rows — in
    /// sync with the running VMs.
    private var runningObservation: ObservationLoop?
    /// Keeps the icon/tooltip in sync with the host File Provider toggle.
    private var fileProviderObservation: ObservationLoop?
    /// Keeps the paste readout in sync with the materializing transfer.
    private var pasteProgressObservation: ObservationLoop?

    /// The dropdown readout, its one-shot automatic open, and the shared menu
    /// wiring for a materializing paste.
    ///
    /// Dismisses the soft-quit reminder before an automatic open, so the click
    /// reaches the menu rather than the reminder's dismissal handler.
    private lazy var pasteProgressPresenter = ClipboardProgressStatusItemPresenter(
        statusItem: statusItem, menu: menu,
        willAutoOpen: { [weak self] in self?.dismissSoftQuitReminder() })

    /// Manages the transient "still running in the menu bar" soft-quit reminder
    /// popover.
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

        runningObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                for instance in self.viewModel.instances {
                    _ = instance.isKeepingAppAlive
                    _ = instance.name
                }
            },
            apply: { [weak self] in
                guard let self else { return }
                self.updateTooltip()
                self.syncMenuIfOpen()
            }
        )

        fileProviderObservation = observeRecurring(
            track: { _ = HostClipboardFileProvider.shared.availability },
            apply: { [weak self] in self?.fileProviderAvailabilityChanged() }
        )

        pasteProgressObservation = observeRecurring(
            track: { _ = HostClipboardFileProvider.shared.materializationProgress },
            apply: { [weak self] in self?.pasteProgressChanged() }
        )
    }

    // MARK: - Paste progress

    private func pasteProgressChanged() {
        pasteProgressPresenter.apply(HostClipboardFileProvider.shared.materializationProgress)
        setIcon()
        updateTooltip()
    }

    // MARK: - Soft-quit reminder

    /// Shows a transient reminder popover anchored to the status item after a soft
    /// quit — unless the user has silenced it.
    ///
    /// Skipped when the status item isn't on screen: macOS hides status items it
    /// can't fit in a crowded menu bar, and a popover anchored to a hidden button
    /// would point at nothing.
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
        // observed on every soft quit with the cursor nowhere near the item), and
        // that open dismisses the reminder via `menuNeedsUpdate` within a frame.
        // Every dismissal path restores the menu.
        statusItem.menu = nil
        button.target = self
        button.action = #selector(statusItemTappedDuringReminder)

        let content = MenuBarQuitReminderViewController(onStopReminding: { [weak self] in
            guard let self else { return }
            self.preferences.menuBarQuitReminderDismissed = true
            Self.logger.info("Soft-quit menu-bar reminder silenced by the user")
            self.dismissSoftQuitReminder()
        })
        // RATIONALE: `.applicationDefined`, not the default `.transient` — a soft
        // quit deactivates the app moments after this shows, and a `.transient`
        // popover auto-closes on app deactivation (see `PopoverPresenter`'s
        // `onClose` doc), so the reminder would vanish before it could be read.
        // Lifetime is bounded instead by the auto-dismiss timer below, the
        // opt-out tap, and a click on the status item.
        softQuitReminder.show(
            content: content, from: button, preferredEdge: .minY, behavior: .applicationDefined)
        Self.logger.debug("Showing soft-quit menu-bar reminder")

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
    private func reattachStatusItemMenu() {
        guard statusItem.menu == nil else { return }
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusItem.menu = menu
    }

    /// Handles a click on the status item while the soft-quit reminder is up and
    /// the dropdown is therefore detached.
    @objc private func statusItemTappedDuringReminder() {
        dismissSoftQuitReminder()
        // Deferred a tick: the menu is reattached above, but popping it from
        // inside the button-action callback the same click is still delivering
        // re-enters menu tracking mid-event.
        performOnMainRunLoop { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    // MARK: - File Provider reminder

    /// Whether the proactive status-item badge should currently show.
    ///
    /// Distinct from the passive menu line below, which shows whenever the
    /// toggle is off regardless of dismissal.
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
        // find (or quit) the headless agent.
        guard
            let image = NSImage(
                systemSymbolName: Self.iconSymbol, accessibilityDescription: "Kernova")
        else {
            Self.logger.fault(
                "Missing SF Symbol '\(Self.iconSymbol, privacy: .public)' for status item")
            assertionFailure("Missing SF Symbol '\(Self.iconSymbol)'")
            statusItem.button?.title = "K"
            return
        }
        image.isTemplate = true
        // A materializing paste outranks the enablement badge.
        if let snapshot = pasteProgressPresenter.snapshot {
            statusItem.button?.image = image.withProgressRing(
                fraction: snapshot.fractionComplete)
            return
        }
        statusItem.button?.image = reminderActive ? image.withAttentionBadge() : image
    }

    /// Updates the tooltip.
    ///
    /// A materializing paste and the reminder append further lines rather than
    /// replacing the running-count line, so headless users never lose the
    /// at-a-glance view of how many VMs are running.
    private func updateTooltip() {
        let count = viewModel.instances.lazy.filter(\.isKeepingAppAlive).count
        var lines: [String]
        switch count {
        case 0: lines = ["Kernova"]
        case 1: lines = ["Kernova — 1 virtual machine running"]
        default: lines = ["Kernova — \(count) virtual machines running"]
        }
        if let snapshot = pasteProgressPresenter.snapshot {
            lines.append(ClipboardProgressFormat.summary(snapshot))
        }
        if reminderActive { lines.append(badgeSummary()) }
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    /// The badge tooltip's second line, picking the `.unavailable` copy so an
    /// install/signing problem reads differently from "flip this toggle".
    private func badgeSummary() -> String {
        HostClipboardFileProvider.shared.availability == .unavailable
            ? ClipboardFileProviderReminder.hostUnavailableSummary()
            : ClipboardFileProviderReminder.hostDegradedSummary()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opening the dropdown means the user found the icon — the soft-quit
        // reminder has done its job.
        dismissSoftQuitReminder()

        menu.removeAllItems()

        pasteProgressPresenter.insertItemsIfActive()

        let open = NSMenuItem(title: "Open Kernova", action: #selector(openTapped), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        // Passive affordance: shown whenever the toggle is off, independent of
        // whether the proactive badge reminder was dismissed.
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
            // Registration/install failure — no user toggle to flip, so no
            // enable/stop commands.
            addInfoItem(ClipboardFileProviderReminder.hostUnavailableSummary())
            menu.addItem(.separator())
        }

        vmSection.rebuild(rows: StatusMenuVMSection.rows(for: viewModel.instances))

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Kernova", action: #selector(quitTapped), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        pasteProgressPresenter.menuWillOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        pasteProgressPresenter.menuDidClose()
    }

    /// Re-syncs the dropdown's VM rows if it is on screen; a closed menu is
    /// rebuilt by `menuNeedsUpdate` when it next opens.
    private func syncMenuIfOpen() {
        guard isMenuOpen else { return }
        vmSection.sync(to: StatusMenuVMSection.rows(for: viewModel.instances))
    }

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
