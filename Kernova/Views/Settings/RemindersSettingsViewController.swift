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
/// app-wide *Guest Agent Install Reminder* by
/// `VMLibraryViewModel.agentInstallPromptDisabled`, which overrides every
/// per-VM row below it; the per-VM *guest-agent install nudge* rows are backed
/// by each VM's bundle configuration and written through
/// `VMLibraryViewModel.setAgentInstallNudgeDismissed(_:for:)`.
///
/// `viewWillAppear()` rebuilds the per-VM rows from `viewModel.instances` and
/// refreshes every switch from current state; an `observeRecurring` loop, live
/// for as long as the pane is on screen, redoes both whenever the VM list or a
/// VM's nudge flag changes. Settings is a separate window from the main one, so
/// VMs can be created or deleted — and the same nudge dismissed from the sidebar
/// popover or VM Settings — while this pane is visible.
@MainActor
final class RemindersSettingsViewController: NSViewController, SettingsPaneScrollCueing {
    private static let logger = Logger(subsystem: "app.kernova", category: "RemindersSettingsViewController")

    /// Height at which the pane stops growing and starts scrolling — keeps a
    /// long VM list from making the Settings window unreasonably tall.
    private static let maxPaneHeight: CGFloat = 520

    private let preferences: AppPreferences
    private let viewModel: VMLibraryViewModel

    private let menuBarQuitSwitch = NSSwitch()
    private let agentInstallSwitch = NSSwitch()

    /// The persistent container in the content stack that holds either the
    /// per-VM card or the empty-state caption, rebuilt on every appear.
    private let vmSection = NSStackView()
    /// The live per-VM switches, paired with their VM and row label, rebuilt on
    /// every appear.
    ///
    /// The label is grayed in step with a disabled switch.
    private var vmSwitches: [(instance: VMInstance, control: NSSwitch, label: NSTextField)] = []
    /// Explains the disabled per-VM rows while the app-wide switch is off.
    private var vmCaption = NSTextField()
    private var vmOverrideCaption = NSTextField()
    /// Flashes the pane's scroller when its content overflows the viewport,
    /// signaling there's more below.
    private var scrollMoreIndicator: ScrollMoreIndicator?

    #if DEBUG
    /// The more-below indicator, so a test can assert the flash re-arms when
    /// the pane's content grows and stays latched when it doesn't.
    var scrollMoreIndicatorForTesting: ScrollMoreIndicator? { scrollMoreIndicator }
    #endif
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
        agentInstallSwitch.controlSize = .small
        agentInstallSwitch.target = self
        agentInstallSwitch.action = #selector(agentInstallToggled)

        // One card per reminder, each with its own caption, so no description has
        // to name the switch it belongs to.
        let menuBarCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Menu Bar Quit Reminder", control: menuBarQuitSwitch)
        ])
        let menuBarCaption = makeGroupedFormCaption(
            "Appears when you quit (⌘Q) and Kernova keeps running in the menu bar, reminding you "
                + "it — and your virtual machines — are still going.")

        // The governing control of the Virtual Machine Reminders section, so it
        // heads that section rather than sitting with the app reminder above.
        let agentInstallCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Guest Agent Install Reminder", control: agentInstallSwitch)
        ])
        let agentInstallCaption = makeGroupedFormCaption(
            "The sidebar prompt to install the Kernova guest agent on a running macOS virtual "
                + "machine.")

        // Per-VM reminders: rebuilt on every appear (VMs may be added or removed).
        vmSection.orientation = .vertical
        vmSection.alignment = .leading
        vmSection.spacing = Spacing.none
        vmCaption = makeGroupedFormCaption(
            "Turn a virtual machine off to stop its own reminder. This has no effect once the "
                + "agent is installed.")
        vmOverrideCaption = makeGroupedFormCaption(
            "The reminder above is off, so these have no effect. Turn it back on to choose per "
                + "virtual machine.")
        vmOverrideCaption.isHidden = true

        // Indented beneath the switch that governs them, the alignment Apple's
        // guidance uses to show a control's subordinates.
        let vmSubordinates = NSStackView(views: [vmSection, vmCaption, vmOverrideCaption])
        vmSubordinates.orientation = .vertical
        vmSubordinates.alignment = .leading
        vmSubordinates.spacing = Spacing.small
        vmSubordinates.translatesAutoresizingMaskIntoConstraints = false
        // A plain container, not an arranged subview of `content` directly: the
        // content stack pins its members' leading edges to its own, which an
        // inset applied out there would fight. Holding the inset inside keeps
        // the container full-width and the stack's alignment satisfied.
        let vmGroup = NSView()
        vmGroup.addSubview(vmSubordinates)
        NSLayoutConstraint.activate([
            vmSubordinates.topAnchor.constraint(equalTo: vmGroup.topAnchor),
            vmSubordinates.bottomAnchor.constraint(equalTo: vmGroup.bottomAnchor),
            vmSubordinates.leadingAnchor.constraint(
                equalTo: vmGroup.leadingAnchor, constant: groupedFormSubOptionIndent),
            vmSubordinates.trailingAnchor.constraint(equalTo: vmGroup.trailingAnchor),
        ])
        for member in [vmSection, vmCaption, vmOverrideCaption] {
            member.widthAnchor.constraint(equalTo: vmSubordinates.widthAnchor).isActive = true
        }

        let resetButton = NSButton(
            title: "Reset All Reminders", target: self, action: #selector(resetAllReminders))
        resetButton.bezelStyle = .push
        resetButton.controlSize = .small
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        let resetCaption = makeGroupedFormCaption(
            "Turns every reminder above back on, including for all virtual machines.")

        let content = NSStackView(views: [
            makeGroupedFormSectionHeader("App Reminders"),
            menuBarCard,
            menuBarCaption,
            makeGroupedFormSectionHeader("Virtual Machine Reminders"),
            agentInstallCard,
            agentInstallCaption,
            vmGroup,
            resetButton,
            resetCaption,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Spacing.small
        // A caption closes its group, so the gap after one is what separates
        // blocks. The governing switch's caption keeps the tighter step, so its
        // subordinates read as continuing the same group rather than opening a
        // new one.
        content.setCustomSpacing(Spacing.section, after: menuBarCaption)
        content.setCustomSpacing(Spacing.section, after: vmGroup)

        // Full-width members (cards and wrapping captions). The reset button is
        // intentionally excluded so it hugs its intrinsic width at the leading edge.
        for member in [
            menuBarCard, menuBarCaption, agentInstallCard, agentInstallCaption,
            vmGroup, resetCaption,
        ] {
            member.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        // Scroll when the VM list grows past the cap; hug content when short.
        let scrollView = makeGroupedFormScrollView(
            documentView: content, topInset: Spacing.large, bottomInset: Spacing.large)
        // Let the pane's size flow from its content (see the General/Advanced
        // panes for why the root must not use autoresizing-mask constraints).
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Flash-only (no chevron/fade overlays): this scroll view *is* the pane's
        // root, so it has no superview of its own to host them until the tab view
        // adopts it. The window is sized once per tab selection, so content that
        // grows while the pane is on screen — a VM added or removed, the override
        // caption appearing — overflows in place; the flash is what says so.
        // Not armed at birth: the tab container cues every arrival explicitly,
        // and a born-armed flash fires from `viewWillAppear`'s layout churn — in
        // the already-visible window, behind the tab transition — so the first
        // visit would meet a scroller already at full alpha.
        scrollMoreIndicator = ScrollMoreIndicator(
            scrollView: scrollView, cues: .flash, flashOnFirstOverflow: false)

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
    /// Tracks the VM list's identity, each VM's nudge flag, *and* the app-wide
    /// suppression, so a VM created or deleted in the main window, or a nudge
    /// dismissed from the sidebar popover or VM Settings, is reflected here
    /// without a tab round-trip.
    private func startVMObservation() {
        vmObservation?.cancel()
        vmObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = viewModel.agentInstallPromptDisabled
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
        let previousRowCount = vmSwitches.count
        rebuildVMRows()
        refreshSwitches()
        if previousRowCount != vmSwitches.count { rearmScrollFlash() }
    }

    /// Re-arms the flash for a fresh appearance, so arriving at an overflowing
    /// pane cues every visit rather than only the first.
    func rearmScrollMoreCue() {
        rearmScrollFlash()
    }

    /// Re-arms the "more below" scroller flash after the pane's content height
    /// changes while it is on screen.
    ///
    /// The window is sized once per tab selection, so content that grows
    /// afterwards overflows in place with nothing to say so. Layout has to
    /// settle first: overflow is measured against the document's real height,
    /// and an un-laid-out subtree still reports the old one.
    ///
    /// Skipped before the pane has a height, which is where the first row build
    /// runs: every content height beats a zero-height viewport, so re-arming
    /// there would latch the flash against geometry the user never sees and
    /// spend the cue the pane's actual appearance needs.
    private func rearmScrollFlash() {
        guard view.frame.height > 0 else { return }
        view.layoutSubtreeIfNeeded()
        scrollMoreIndicator?.rearmFlash()
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
            var rowLabel = NSTextField()
            let row = makeGroupedFormCardRow(
                instance.name, control: toggle, titleLabel: { rowLabel = $0 })
            vmSwitches.append((instance, toggle, rowLabel))
            rows.append(row)
        }

        let card = makeGroupedFormCard(rows: rows)
        vmSection.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: vmSection.widthAnchor).isActive = true
    }

    /// Mirrors every switch to current state — ON when the reminder is shown
    /// (its dismissed flag is `false`).
    ///
    /// A per-VM row keeps showing what its VM reverts to while the app-wide
    /// install reminder is off; it just can't be changed until that goes back on.
    private func refreshSwitches() {
        menuBarQuitSwitch.state = preferences.menuBarQuitReminderDismissed ? .off : .on
        let overridden = viewModel.agentInstallPromptDisabled
        agentInstallSwitch.state = overridden ? .off : .on

        // Both captions talk about the per-VM switches. With no VMs the section
        // is a lone "No virtual machines yet." row, so they would be describing
        // controls that aren't on screen.
        let hasVMs = !vmSwitches.isEmpty
        vmCaption.isHidden = !hasVMs
        let showOverrideCaption = overridden && hasVMs
        let wasShowingOverrideCaption = !vmOverrideCaption.isHidden
        vmOverrideCaption.isHidden = !showOverrideCaption

        for (instance, toggle, label) in vmSwitches {
            toggle.state = instance.configuration.agentInstallNudgeDismissed ? .off : .on
            toggle.isEnabled = !overridden
            // AppKit fades the disabled switch but not its label, which leaves
            // the row half-lit; gray the text in step so the row reads as inert.
            label.textColor = overridden ? .disabledControlTextColor : .labelColor
        }

        if wasShowingOverrideCaption != showOverrideCaption { rearmScrollFlash() }
    }

    @objc private func menuBarQuitToggled() {
        preferences.menuBarQuitReminderDismissed = (menuBarQuitSwitch.state == .off)
    }

    @objc private func agentInstallToggled() {
        viewModel.agentInstallPromptDisabled = (agentInstallSwitch.state == .off)
        refreshSwitches()
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
