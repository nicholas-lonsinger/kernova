import AppKit
import KernovaKit
import os

/// Owns the resident agent's menu-bar `NSStatusItem` and its dropdown.
///
/// Present for the whole life of the background-agent process — the always-visible
/// "Kernova is running" affordance, and the discoverable way to summon the GUI
/// when the app is headless (`.accessory`, no Dock icon). The dropdown leads with
/// "Open Kernova", lists the VMs running headless (click one to open the library
/// on it), and ends with Quit; it is rebuilt from live view-model state each time
/// it opens. A live tooltip reflects the running count. Mirrors the guest agent's
/// `AgentStatusItemController`.
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
@MainActor
final class HostAgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "app.kernova", category: "HostAgentStatusItem")
    private static let iconSymbol = "macwindow"

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let viewModel: VMLibraryViewModel
    private let preferences: AppPreferences
    /// Summons the GUI; a non-`nil` id selects that VM first.
    private let onOpen: (UUID?) -> Void
    private let onQuit: () -> Void

    /// Keeps the tooltip in sync with how many VMs are running headless.
    private var runningObservation: ObservationLoop?
    /// Keeps the icon/tooltip in sync with the host File Provider toggle.
    private var fileProviderObservation: ObservationLoop?

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
        statusItem.button?.image = reminderActive ? image.withAttentionBadge() : image
    }

    /// Updates the tooltip.
    ///
    /// The running-count line always shows (the class's
    /// own promise); the reminder — when active — appends as a second line
    /// rather than replacing it, so headless users don't lose the only
    /// at-a-glance view of how many VMs are running (#581).
    private func updateTooltip() {
        let count = viewModel.instances.lazy.filter(\.isKeepingAppAlive).count
        let countLine: String
        switch count {
        case 0: countLine = "Kernova"
        case 1: countLine = "Kernova — 1 virtual machine running"
        default: countLine = "Kernova — \(count) virtual machines running"
        }
        guard reminderActive else {
            statusItem.button?.toolTip = countLine
            return
        }
        statusItem.button?.toolTip = "\(countLine)\n\(badgeSummary())"
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
        menu.removeAllItems()

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
