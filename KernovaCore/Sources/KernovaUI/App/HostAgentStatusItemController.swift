import AppKit
import KernovaAppKitShared
import KernovaCore
import KernovaKit
import KernovaLogging

/// Owns the resident agent's menu-bar `NSStatusItem` and its dropdown.
///
/// The always-visible "Kernova is running" affordance and the way to summon the
/// GUI when the app is headless (`.accessory`, no Dock icon), so it lives for
/// the whole life of the process. The dropdown is rebuilt from live view-model
/// state each time it opens, and its VM rows are edited in place while it is on
/// screen so the readout tracks starts, stops, and status transitions live.
@MainActor
final class HostAgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HostAgentStatusItem")
    private static let idleIconSymbol = "macwindow"
    /// SF Symbols draws no badged variant of `macwindow`, so the undone-start
    /// state takes the badged screen glyph — a symbol the set already draws for
    /// menu-bar sizes — rather than a composited badge.
    private static let undoneStartIconSymbol = "display.trianglebadge.exclamationmark"
    private static let waitingAlertIconSymbol = "exclamationmark.bubble"

    /// The glyph the status item shows, which reports alerts held for want of a
    /// window: a start left undone first, then any other.
    static func iconSymbol(hasUndoneStarts: Bool, hasWaitingAlerts: Bool) -> String {
        if hasUndoneStarts { return undoneStartIconSymbol }
        return hasWaitingAlerts ? waitingAlertIconSymbol : idleIconSymbol
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    /// The dropdown's VM rows, edited in place while the menu is on screen.
    private lazy var vmSection = StatusMenuVMSection(
        menu: menu, rowTarget: self, rowAction: #selector(openVMTapped(_:)))
    /// The dropdown's undone-start line, edited in place the same way.
    private lazy var undoneStartLine = StatusMenuCountLine(
        menu: menu, target: self, action: #selector(heldAlertsTapped),
        title: StatusMenuCountLine.undoneStartTitle(count:))
    /// The dropdown's line for every other held alert, under the undone-start
    /// line.
    private lazy var waitingAlertLine = StatusMenuCountLine(
        menu: menu, target: self, action: #selector(heldAlertsTapped),
        title: StatusMenuCountLine.waitingAlertTitle(count:))
    /// The item the held-alert lines sit under, so an in-place insertion has
    /// an anchor while the dropdown is open.
    private var openItem: NSMenuItem?
    /// Whether the dropdown is currently on screen, which `NSMenu` doesn't
    /// expose; gates the live row sync.
    private var isMenuOpen = false

    private let viewModel: VMLibraryViewModel
    /// The alerts waiting for a window to show them on.
    private let heldAlerts: HeldAlerts
    private var preferences: AppPreferences { viewModel.preferences }
    /// Summons the GUI — `nil` opens the library, a VM id opens just that VM.
    private let onOpen: (UUID?) -> Void
    /// Opens the clipboard window of the VM a notice names.
    private let onOpenClipboard: (UUID) -> Void
    private let onQuit: () -> Void

    /// Keeps the tooltip, the readout, the notice popover and — while the
    /// dropdown is open — its VM rows in sync with the library.
    ///
    /// One loop, not several: every one of those renders from the same tracked
    /// set (each VM's row model and its transfer report), so splitting them would
    /// only let the tracked set drift from the rendered one.
    private var libraryObservation: ObservationLoop?

    /// The dropdown readout, its one-shot reveal in the popover slot, and the
    /// shared menu wiring for a transfer in flight.
    private lazy var transferProgressPresenter = ClipboardProgressStatusItemPresenter(
        menu: menu, slot: transientPopover,
        onCancel: { [weak self] id in self?.cancelTransfer(id) })

    /// The status item's one transient-popover slot, shared by the transfer
    /// readout's callout, the soft-quit reminder and the clipboard notice.
    private lazy var transientPopover = TransientStatusItemPopover(
        statusItem: statusItem, menu: menu,
        isDropdownOpen: { [weak self] in self?.isMenuOpen ?? false })

    /// The readout last handed to the presenter, so a library change that leaves
    /// it alone doesn't re-run the reveal decision.
    private var lastAppliedReadout: ClipboardTransferReport = .idle

    /// The held-alert counts the icon was last drawn for, so a library change
    /// that leaves them alone doesn't redraw the button.
    private var lastHeldCounts = HeldCounts(undoneStarts: 0, waitingAlerts: 0)

    /// What the status item reports of the held alerts.
    private struct HeldCounts: Equatable {
        /// VMs that did not start, still in the library.
        let undoneStarts: Int
        /// Every other held alert.
        let waitingAlerts: Int
    }

    /// The held alerts as they stand, counting only what the library still
    /// lists — what showing them would show.
    private var heldCounts: HeldCounts {
        let instances = viewModel.instances
        let isListed: (UUID) -> Bool = { id in instances.contains { $0.id == id } }
        return HeldCounts(
            undoneStarts: heldAlerts.undoneStartCount(listing: isListed),
            waitingAlerts: heldAlerts.otherAlertCount(listing: isListed))
    }

    /// Which surface presents each VM's refusal.
    private var noticeLedger = ClipboardNoticeLedger()

    /// How long a clipboard notice stays up unattended.
    private static let clipboardNoticeDuration: TimeInterval = 6

    /// How long the soft-quit reminder stays up unattended.
    private static let softQuitReminderDuration: TimeInterval = 4.5

    init(
        viewModel: VMLibraryViewModel,
        heldAlerts: HeldAlerts,
        onOpen: @escaping (UUID?) -> Void,
        onOpenClipboard: @escaping (UUID) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.viewModel = viewModel
        self.heldAlerts = heldAlerts
        self.onOpen = onOpen
        self.onOpenClipboard = onOpenClipboard
        self.onQuit = onQuit
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        setIcon()
        updateTooltip()

        libraryObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                // Evaluating the row model registers every property the rows
                // (and the tooltip's running count) render, so the tracked set
                // can't drift from the rendered set.
                _ = self.currentRows()
                for instance in self.viewModel.instances {
                    _ = instance.clipboardTransferReport
                }
                _ = self.heldCounts
            },
            apply: { [weak self] in
                guard let self else { return }
                self.transferReportsChanged()
                self.heldAlertsChanged()
                self.syncMenuIfOpen()
                self.presentPendingNotices()
            }
        )
    }

    /// Removes the status item from the menu bar and stops every observation.
    ///
    /// Explicit rather than left to deallocation: `NSStatusBar` holds its own
    /// reference to a status item until it is removed, and a popover still up
    /// owns a live auto-dismiss task.
    func tearDown() {
        libraryObservation?.cancel()
        transientPopover.dismiss()
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// The dropdown's VM rows for the current library.
    private func currentRows() -> [StatusMenuVMRow] {
        StatusMenuVMSection.rows(for: viewModel.entries)
    }

    // MARK: - Transfer readout

    /// Stops the operation the readout on screen was rendered for.
    private func cancelTransfer(_ id: ClipboardTransferOperationID) {
        guard !AppClipboardReadout.cancel(id, in: viewModel.instances) else { return }
        Self.logger.log(.notice, "Cancel found no live transfer for the readout it was shown on")
    }

    /// Applies the readout across every VM.
    ///
    /// The tooltip is rebuilt every pass — it also carries the running-VM count —
    /// while the readout itself is applied only when it changed, so a start or a
    /// status transition doesn't re-run the reveal decision.
    private func transferReportsChanged() {
        let readout = AppClipboardReadout.report(for: viewModel.instances)
        if readout != lastAppliedReadout {
            lastAppliedReadout = readout
            transferProgressPresenter.apply(readout)
            setIcon()
        }
        updateTooltip()
    }

    // MARK: - Held alerts

    /// Re-draws the icon when the alerts waiting for a window change — the
    /// resident app's only way to report them.
    private func heldAlertsChanged() {
        let counts = heldCounts
        guard counts != lastHeldCounts else { return }
        lastHeldCounts = counts
        setIcon()
    }

    // MARK: - Clipboard notice

    /// Presents each VM's newly raised refusal where ``ClipboardNoticeLedger``
    /// routes it.
    ///
    /// A notice the status item can't carry is dropped rather than deferred:
    /// the dropdown's own line is the fallback, and a refusal replayed later
    /// would interrupt for something the user has moved past. A refusal the
    /// *guest* user's gesture produced is not presented here at all — the
    /// guest's own status item announces it over there.
    private func presentPendingNotices() {
        for instance in viewModel.instances {
            guard case .finished(let finish) = instance.clipboardTransferReport,
                finish.failure != nil, finish.gesture.isMadeHere,
                let wording = ClipboardTransferWording.wording(
                    for: finish, vmName: instance.name),
                noticeLedger.route(finish.date, for: instance.instanceID, dropdownIsOpen: isMenuOpen)
                    == .notice
            else { continue }
            let instanceID = instance.instanceID
            let content = ClipboardNoticeViewController(wording: wording) { [weak self] in
                guard let self else { return }
                self.transientPopover.dismiss()
                self.onOpenClipboard(instanceID)
            }
            if case .skipped(let reason) = transientPopover.show(
                content, for: Self.clipboardNoticeDuration)
            {
                Self.logger.log(
                    .info,
                    "Clipboard notice for '\(instance.name, privacy: .public)' skipped — \(String(describing: reason), privacy: .public)"
                )
                continue
            }
            Self.logger.log(
                .notice,
                "Showing a clipboard notice for '\(instance.name, privacy: .public)'")
        }
    }

    // MARK: - Soft-quit reminder

    /// Shows a transient reminder popover anchored to the status item after a soft
    /// quit — unless the user has silenced it.
    func showSoftQuitReminder() {
        guard !preferences.menuBarQuitReminderDismissed else { return }

        let content = MenuBarQuitReminderViewController(onStopReminding: { [weak self] in
            guard let self else { return }
            self.preferences.menuBarQuitReminderDismissed = true
            Self.logger.log(.info, "Soft-quit menu-bar reminder silenced by the user")
            self.transientPopover.dismiss()
        })
        if case .skipped(let reason) = transientPopover.show(
            content, for: Self.softQuitReminderDuration)
        {
            Self.logger.log(
                .info,
                "Soft-quit reminder skipped — \(String(describing: reason), privacy: .public)")
            return
        }
        Self.logger.log(.debug, "Showing soft-quit menu-bar reminder")
    }

    // MARK: - Icon / tooltip

    private func setIcon() {
        let counts = heldCounts
        let hasUndoneStarts = counts.undoneStarts > 0
        let hasWaitingAlerts = counts.waitingAlerts > 0
        let symbol = Self.iconSymbol(hasUndoneStarts: hasUndoneStarts, hasWaitingAlerts: hasWaitingAlerts)
        // The glyph is the whole signal for a sighted user; the description is
        // the whole of it for VoiceOver, so it changes with the glyph.
        let description =
            hasUndoneStarts
            ? "Kernova, a virtual machine didn\u{2019}t start"
            : hasWaitingAlerts ? "Kernova, an alert is waiting" : "Kernova"
        // The shared `NSImage.systemSymbol(_:…)` helper's release fallback is a
        // zero-size `NSImage()`, which renders the status-item button invisible,
        // and the status item is the only way to find or quit the headless agent.
        guard
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        else {
            Self.logger.log(
                .fault,
                "Missing SF Symbol '\(symbol, privacy: .public)' for status item")
            assertionFailure("Missing SF Symbol '\(symbol)'")
            statusItem.button?.title = "K"
            return
        }
        image.isTemplate = true
        if let snapshot = transferProgressPresenter.snapshot {
            statusItem.button?.image = image.withProgressRing(
                fraction: snapshot.fractionComplete)
            return
        }
        statusItem.button?.image = image
    }

    /// Updates the tooltip.
    ///
    /// A materializing paste and each kind of held alert append a further line
    /// rather than replacing the running-count line, so headless users never
    /// lose the at-a-glance view of how many VMs are running.
    private func updateTooltip() {
        let count =
            viewModel.instances.lazy.filter(\.isKeepingAppAlive).count + viewModel.arrivals.count
        var lines: [String]
        switch count {
        case 0: lines = ["Kernova"]
        case 1: lines = ["Kernova — 1 virtual machine running"]
        default: lines = ["Kernova — \(count) virtual machines running"]
        }
        if let snapshot = transferProgressPresenter.snapshot {
            lines.append(ClipboardProgressFormat.summary(snapshot))
        }
        let counts = heldCounts
        switch counts.undoneStarts {
        case ..<1: break
        case 1: lines.append("1 virtual machine didn\u{2019}t start")
        case let undone: lines.append("\(undone) virtual machines didn\u{2019}t start")
        }
        switch counts.waitingAlerts {
        case ..<1: break
        case 1: lines.append("1 alert is waiting to be shown")
        case let waiting: lines.append("\(waiting) alerts are waiting to be shown")
        }
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Opening the dropdown means the user found the icon — the soft-quit
        // reminder has done its job, and the notice's line and the readout are
        // in the menu below.
        transientPopover.dismiss()

        menu.removeAllItems()

        transferProgressPresenter.insertItemsIfActive()

        let open = NSMenuItem(title: "Open Kernova", action: #selector(openTapped), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        openItem = open

        let counts = heldCounts
        undoneStartLine.rebuild(count: counts.undoneStarts)
        waitingAlertLine.rebuild(count: counts.waitingAlerts)

        menu.addItem(.separator())

        vmSection.rebuild(rows: currentRows())

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Kernova", action: #selector(quitTapped), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    /// Re-syncs the dropdown's VM rows and held-alert lines if it is on screen;
    /// a closed menu is rebuilt by `menuNeedsUpdate` when it next opens.
    private func syncMenuIfOpen() {
        guard isMenuOpen else { return }
        vmSection.sync(to: currentRows())
        if let openItem {
            let counts = heldCounts
            undoneStartLine.sync(to: counts.undoneStarts, after: openItem)
            waitingAlertLine.sync(
                to: counts.waitingAlerts, after: undoneStartLine.item ?? openItem)
        }
    }

    // MARK: - Actions

    @objc private func openTapped() { onOpen(nil) }

    /// Opens the library, which every held alert can be shown on.
    @objc private func heldAlertsTapped() { onOpen(nil) }

    @objc private func openVMTapped(_ sender: NSMenuItem) {
        onOpen(sender.representedObject as? UUID)
    }

    @objc private func quitTapped() { onQuit() }
}
