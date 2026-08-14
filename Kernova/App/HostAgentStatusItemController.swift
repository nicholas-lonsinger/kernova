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
    private let issueCenter: ClipboardIssueCenter
    /// Summons the GUI — `nil` opens the library, a VM id opens just that VM.
    private let onOpen: (UUID?) -> Void
    /// Opens the clipboard window of the VM a notice names.
    private let onOpenClipboard: (UUID) -> Void
    private let onQuit: () -> Void

    /// Keeps the tooltip — and, while the dropdown is open, its VM rows — in
    /// sync with the running VMs.
    private var runningObservation: ObservationLoop?
    /// Keeps the paste readout in sync with the materializing transfer.
    private var pasteProgressObservation: ObservationLoop?
    /// Fires when a clipboard refusal is queued for an interrupting surface.
    private var clipboardNoticeObservation: ObservationLoop?

    /// The dropdown readout, its one-shot automatic open, and the shared menu
    /// wiring for a materializing paste.
    ///
    /// Dismisses any transient popover before an automatic open, so the click
    /// reaches the reattached menu rather than the popover's dismissal handler.
    private lazy var pasteProgressPresenter = ClipboardProgressStatusItemPresenter(
        statusItem: statusItem, menu: menu,
        willAutoOpen: { [weak self] in self?.transientPopover.dismiss() },
        onCancel: { ClipboardProgressCenter.shared.cancelCurrent() })

    /// The status item's one transient-popover slot, shared by the soft-quit
    /// reminder and the clipboard notice.
    private lazy var transientPopover = TransientStatusItemPopover(
        statusItem: statusItem, menu: menu,
        isDropdownOpen: { [weak self] in self?.isMenuOpen ?? false })

    /// The notice currently shown, or the last one declined.
    ///
    /// One refusal is presented once. A repeat of the same kind is a new notice,
    /// since the issue's `date` is its identity.
    private var lastPresentedNotice: ClipboardIssueCenter.Notice?

    /// How long a clipboard notice stays up unattended.
    private static let clipboardNoticeDuration: Duration = .seconds(6)

    /// How long the soft-quit reminder stays up unattended.
    private static let softQuitReminderDuration: Duration = .seconds(4.5)

    init(
        viewModel: VMLibraryViewModel,
        preferences: AppPreferences = .shared,
        issueCenter: ClipboardIssueCenter = .shared,
        onOpen: @escaping (UUID?) -> Void,
        onOpenClipboard: @escaping (UUID) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.viewModel = viewModel
        self.preferences = preferences
        self.issueCenter = issueCenter
        self.onOpen = onOpen
        self.onOpenClipboard = onOpenClipboard
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
                // Evaluating the row model registers every property the rows
                // (and the tooltip's running count) render, so the tracked set
                // can't drift from the rendered set.
                _ = self.currentRows()
            },
            apply: { [weak self] in
                guard let self else { return }
                self.updateTooltip()
                self.syncMenuIfOpen()
            }
        )

        pasteProgressObservation = observeRecurring(
            track: { _ = ClipboardProgressCenter.shared.materializationProgress },
            apply: { [weak self] in self?.pasteProgressChanged() }
        )

        clipboardNoticeObservation = observeRecurring(
            track: { [weak self] in _ = self?.issueCenter.pendingNotice },
            apply: { [weak self] in self?.pendingClipboardNoticeChanged() }
        )
    }

    /// Removes the status item from the menu bar and stops every observation.
    ///
    /// Explicit rather than left to deallocation: `NSStatusBar` holds its own
    /// reference to a status item until it is removed, and a popover still up
    /// owns a live auto-dismiss task.
    func tearDown() {
        runningObservation?.cancel()
        pasteProgressObservation?.cancel()
        clipboardNoticeObservation?.cancel()
        transientPopover.dismiss()
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// The dropdown's VM rows for the current library and clipboard issues.
    private func currentRows() -> [StatusMenuVMRow] {
        StatusMenuVMSection.rows(
            for: viewModel.instances, issues: issueCenter.latestByInstance)
    }

    // MARK: - Paste progress

    private func pasteProgressChanged() {
        pasteProgressPresenter.apply(ClipboardProgressCenter.shared.materializationProgress)
        setIcon()
        updateTooltip()
    }

    // MARK: - Clipboard notice

    /// Presents the clipboard refusal the issue center just queued, if the status
    /// item can carry a popover right now.
    ///
    /// A notice that can't be shown is dropped rather than deferred: the
    /// dropdown's own line is the fallback, and a refusal replayed later would
    /// interrupt for something the user has moved past.
    private func pendingClipboardNoticeChanged() {
        guard let notice = issueCenter.pendingNotice, notice != lastPresentedNotice else { return }
        lastPresentedNotice = notice
        issueCenter.consumePendingNotice()

        let content = ClipboardNoticeViewController(notice: notice) { [weak self] in
            guard let self else { return }
            self.transientPopover.dismiss()
            self.onOpenClipboard(notice.instanceID)
        }
        guard
            transientPopover.show(
                content, for: Self.clipboardNoticeDuration, describedAs: "Clipboard notice")
        else { return }
        Self.logger.notice(
            "Showing a clipboard notice for '\(notice.vmName, privacy: .public)'")
    }

    // MARK: - Soft-quit reminder

    /// Shows a transient reminder popover anchored to the status item after a soft
    /// quit — unless the user has silenced it.
    func showSoftQuitReminder() {
        guard !preferences.menuBarQuitReminderDismissed else { return }

        let content = MenuBarQuitReminderViewController(onStopReminding: { [weak self] in
            guard let self else { return }
            self.preferences.menuBarQuitReminderDismissed = true
            Self.logger.info("Soft-quit menu-bar reminder silenced by the user")
            self.transientPopover.dismiss()
        })
        guard
            transientPopover.show(
                content, for: Self.softQuitReminderDuration, describedAs: "Soft-quit reminder")
        else { return }
        Self.logger.debug("Showing soft-quit menu-bar reminder")
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
        if let snapshot = pasteProgressPresenter.snapshot {
            statusItem.button?.image = image.withProgressRing(
                fraction: snapshot.fractionComplete)
            return
        }
        statusItem.button?.image = image
    }

    /// Updates the tooltip.
    ///
    /// A materializing paste appends a further line rather than replacing the
    /// running-count line, so headless users never lose the at-a-glance view of
    /// how many VMs are running.
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
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opening the dropdown means the user found the icon — the soft-quit
        // reminder has done its job, and the notice's line is in the menu below.
        transientPopover.dismiss()

        menu.removeAllItems()

        pasteProgressPresenter.insertItemsIfActive()

        let open = NSMenuItem(title: "Open Kernova", action: #selector(openTapped), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        vmSection.rebuild(rows: currentRows())

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
        vmSection.sync(to: currentRows())
    }

    // MARK: - Actions

    @objc private func openTapped() { onOpen(nil) }

    @objc private func openVMTapped(_ sender: NSMenuItem) {
        onOpen(sender.representedObject as? UUID)
    }

    @objc private func quitTapped() { onQuit() }
}
