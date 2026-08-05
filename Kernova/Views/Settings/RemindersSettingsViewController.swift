import AppKit
import os

/// The "Reminders" pane of the Settings window.
///
/// Surfaces every host-side reminder Kernova can suppress, with a switch to turn
/// each back on, plus a *Reset All Reminders* action. Each switch's polarity is
/// **ON = the reminder is shown** (its dismissed flag is `false`), matching the
/// VM Settings pane's "Show install reminder" toggle.
///
/// The app-wide *Menu Bar Quit Reminder* is backed by `AppPreferences`; the
/// per-VM *guest-agent install nudge* rows are backed by each VM's bundle
/// configuration and written through
/// `VMLibraryViewModel.setAgentInstallNudgeDismissed(_:for:)`.
///
/// `viewWillAppear()` rebuilds the per-VM rows from `viewModel.instances` and
/// refreshes every switch from current state; an `observeRecurring` loop, live
/// for as long as the pane is on screen, redoes both whenever the VM list or a
/// VM's nudge flag changes. Settings is a separate window from the main one, so
/// VMs can be created or deleted — and the same nudge dismissed from the sidebar
/// popover or VM Settings — while this pane is visible.
@MainActor
final class RemindersSettingsViewController: NSViewController {
    private static let logger = Logger(subsystem: "app.kernova", category: "RemindersSettingsViewController")

    /// Height at which the pane stops growing and starts scrolling — keeps a
    /// long VM list from making the Settings window unreasonably tall.
    private static let maxPaneHeight: CGFloat = 520

    private let preferences: AppPreferences
    private let viewModel: VMLibraryViewModel

    private let menuBarQuitSwitch = NSSwitch()

    /// The persistent container in the content stack that holds either the
    /// per-VM card or the empty-state caption, rebuilt on every appear.
    private let vmSection = NSStackView()
    /// The live per-VM switches, paired with their VM, rebuilt on every appear.
    private var vmSwitches: [(instance: VMInstance, control: NSSwitch)] = []
    /// Keeps the per-VM rows in sync with the library while the pane is visible.
    private var vmObservation: ObservationLoop?

    init(preferences: AppPreferences = .shared, viewModel: VMLibraryViewModel) {
        self.preferences = preferences
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Reminders"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RemindersSettingsViewController does not support NSCoder")
    }

    override func loadView() {
        menuBarQuitSwitch.controlSize = .small
        menuBarQuitSwitch.target = self
        menuBarQuitSwitch.action = #selector(menuBarQuitToggled)

        // App-wide reminders: one card, one row.
        let appCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Menu Bar Quit Reminder", control: menuBarQuitSwitch)
        ])
        let appMenuCaption = makeGroupedFormCaption(
            "The Menu Bar Quit Reminder appears when you quit (⌘Q) and Kernova keeps running in the "
                + "menu bar, reminding you it — and your virtual machines — are still going.")

        // Per-VM reminders: rebuilt on every appear (VMs may be added or removed).
        vmSection.orientation = .vertical
        vmSection.alignment = .leading
        vmSection.spacing = Spacing.none
        let vmCaption = makeGroupedFormCaption(
            "Turn a virtual machine off to stop its sidebar reminder to install the Kernova guest "
                + "agent. This has no effect once the agent is installed.")

        let resetButton = NSButton(
            title: "Reset All Reminders", target: self, action: #selector(resetAllReminders))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        let resetCaption = makeGroupedFormCaption(
            "Turns every reminder above back on, including for all virtual machines.")

        let content = NSStackView(views: [
            makeGroupedFormSectionHeader("App Reminders"),
            appCard,
            appMenuCaption,
            makeGroupedFormSectionHeader("Virtual Machine Reminders"),
            vmSection,
            vmCaption,
            resetButton,
            resetCaption,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Spacing.small
        // Separate each logical group so they read as distinct blocks, matching
        // the General pane's rhythm.
        content.setCustomSpacing(Spacing.section, after: appMenuCaption)
        content.setCustomSpacing(Spacing.section, after: vmCaption)

        // Full-width members (cards and wrapping captions). The reset button is
        // intentionally excluded so it hugs its intrinsic width at the leading edge.
        for member in [appCard, appMenuCaption, vmSection, vmCaption, resetCaption] {
            member.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        // Scroll when the VM list grows past the cap; hug content when short.
        let scrollView = makeGroupedFormScrollView(
            documentView: content, topInset: Spacing.large, bottomInset: Spacing.large)
        // Let the pane's size flow from its content (see the General/Advanced
        // panes for why the root must not use autoresizing-mask constraints).
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // The hug must stay weaker than every subview's compression resistance:
        // once the tab controller fixes the window height at the cap, a
        // stronger hug squeezes the content to fit — collapsing the headers and
        // captions — instead of letting the pane scroll.
        let hugHeight = scrollView.heightAnchor.constraint(
            equalTo: content.heightAnchor, constant: Spacing.large * 2)
        hugHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: SettingsPaneMetrics.width),
            hugHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxPaneHeight),
        ])
        view = scrollView
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshVMRows()
        // Drive NSTabViewController's per-tab window resize from the measured
        // fitting height (clamped by the height cap) — the scroll view otherwise
        // masks the document's intrinsic height. Must happen here, before the
        // tab transition sizes the window: NSTabViewController reads the pane's
        // preferredContentSize when switching and does not react to a later
        // change (e.g. from viewDidLayout).
        //
        // Lay out at the pane's fixed width before measuring: a wrapping
        // caption's intrinsic height stays single-line until a layout pass
        // resolves its wrap width, so an unlaid-out fittingSize under-counts
        // every caption and the pane comes up short.
        view.setFrameSize(NSSize(width: SettingsPaneMetrics.width, height: Self.maxPaneHeight))
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
        startVMObservation()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        vmObservation?.cancel()
        vmObservation = nil
    }

    /// Re-arms the observation that keeps the per-VM rows current while the pane
    /// is on screen.
    ///
    /// Tracks the VM list's identity *and* each VM's nudge flag, so a VM created
    /// or deleted in the main window, or a nudge dismissed from the sidebar
    /// popover or VM Settings, is reflected here without a tab round-trip.
    private func startVMObservation() {
        vmObservation?.cancel()
        vmObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                for instance in viewModel.instances {
                    _ = instance.id
                    _ = instance.name
                    _ = instance.configuration.agentInstallNudgeDismissed
                }
            },
            apply: { [weak self] in
                self?.refreshVMRows()
            }
        )
    }

    /// Rebuilds the per-VM rows and mirrors every switch to current state.
    private func refreshVMRows() {
        rebuildVMRows()
        refreshSwitches()
    }

    /// Rebuilds the per-VM section from `viewModel.instances`: one switch row per
    /// VM, or an empty-state caption when there are none.
    private func rebuildVMRows() {
        for view in vmSection.arrangedSubviews {
            vmSection.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        vmSwitches.removeAll()

        guard !viewModel.instances.isEmpty else {
            let empty = makeGroupedFormCaption("No virtual machines yet.")
            vmSection.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: vmSection.widthAnchor).isActive = true
            return
        }

        var rows: [NSView] = []
        for instance in viewModel.instances {
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = #selector(vmReminderToggled(_:))
            vmSwitches.append((instance, toggle))
            rows.append(makeGroupedFormCardRow(instance.name, control: toggle))
        }

        let card = makeGroupedFormCard(rows: rows)
        vmSection.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: vmSection.widthAnchor).isActive = true
    }

    /// Mirrors every switch to current state — ON when the reminder is shown
    /// (its dismissed flag is `false`).
    private func refreshSwitches() {
        menuBarQuitSwitch.state = preferences.menuBarQuitReminderDismissed ? .off : .on
        for (instance, toggle) in vmSwitches {
            toggle.state = instance.configuration.agentInstallNudgeDismissed ? .off : .on
        }
    }

    @objc private func menuBarQuitToggled() {
        preferences.menuBarQuitReminderDismissed = (menuBarQuitSwitch.state == .off)
    }

    @objc private func vmReminderToggled(_ sender: NSSwitch) {
        guard let instance = vmSwitches.first(where: { $0.control === sender })?.instance else {
            Self.logger.fault("Toggled VM reminder switch not found in the rebuilt set")
            assertionFailure("Toggled VM reminder switch not found in the rebuilt set")
            return
        }
        viewModel.setAgentInstallNudgeDismissed(sender.state == .off, for: instance)
    }

    @objc private func resetAllReminders() {
        Self.logger.notice("User reset all host reminders")
        preferences.resetHostReminders()
        viewModel.resetAllAgentInstallNudges()
        refreshSwitches()
    }
}
