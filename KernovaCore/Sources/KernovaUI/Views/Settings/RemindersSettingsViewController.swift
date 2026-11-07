import AppKit
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// The "Reminders" pane of the Settings window.
///
/// Surfaces every host-side reminder Kernova can suppress, with a switch to turn
/// each on or off, plus a *Reset All Reminders* action. Each switch's polarity is
/// **ON = the reminder is shown** (its dismissed flag is `false`), matching the
/// VM Settings pane's "Show install reminder" toggle.
///
/// The app-wide *Menu Bar Quit Reminder* is backed by
/// `VMLibraryViewModel.menuBarQuitReminderDismissed`; the
/// *Duplicate machine ID question* by
/// `VMLibraryViewModel.duplicateMachineIDQuestionDismissed`, which Don't ask
/// again on the question itself also turns off; the *Ephemeral Mode settings
/// banner* by `VMLibraryViewModel.ephemeralSettingsBannerDismissed`, which
/// Don't show again on the banner also turns off; the app-wide *Guest Agent
/// Install Reminder* by `VMLibraryViewModel.agentInstallPromptDisabled`, which
/// overrides every per-VM row below it; the per-VM *guest-agent install nudge* rows, one per
/// macOS VM, are backed by each VM's host state and written through
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
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "RemindersSettingsViewController")

    private let viewModel: VMLibraryViewModel
    private var preferences: AppPreferences { viewModel.preferences }
    /// The visible frame the Settings window must fit inside.
    private let visibleFrame: @MainActor (_ window: NSWindow?) -> NSRect?

    /// Caps the pane at ``SettingsPaneMetrics/maxHeight(in:visibleFrame:)``,
    /// past which a long VM list scrolls; re-read on every publish, since the
    /// window may have moved to another screen.
    private var heightCap: NSLayoutConstraint?

    private let menuBarQuitSwitch = NSSwitch()
    private let duplicateIDQuestionSwitch = NSSwitch()
    private let ephemeralSettingsBannerSwitch = NSSwitch()
    /// Explains the duplicate machine ID question's disabled row while the
    /// setting that asks it is off.
    private lazy var duplicateIDQuestionNote = GroupedFormStateNote(
        "No effect while Offer to start duplicate machine IDs anyway is off.",
        shownWhen: { [unowned self] in !preferences.allowsDuplicateMachineIDOverride })
    private let agentInstallSwitch = NSSwitch()

    /// The persistent container in the content stack that holds either the
    /// per-VM card or the empty-state caption, rebuilt on every appear.
    private let vmSection = NSStackView()
    /// The live per-VM switches, paired with their VM and row label, rebuilt on
    /// every appear.
    ///
    /// The label is grayed in step with a disabled switch.
    private var vmSwitches: [(instance: VMInstance, control: NSSwitch)] = []
    /// Explains the disabled per-VM rows while the app-wide switch is off.
    private lazy var vmOverrideCaption = GroupedFormStateNote(
        "No effect while the reminder above is off.",
        shownWhen: { [unowned self] in viewModel.agentInstallPromptDisabled })
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

    init(viewModel: VMLibraryViewModel, visibleFrame: @escaping @MainActor (_ window: NSWindow?) -> NSRect?) {
        self.viewModel = viewModel
        self.visibleFrame = visibleFrame
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
        duplicateIDQuestionSwitch.controlSize = .small
        duplicateIDQuestionSwitch.target = self
        duplicateIDQuestionSwitch.action = #selector(duplicateIDQuestionToggled)
        ephemeralSettingsBannerSwitch.controlSize = .small
        ephemeralSettingsBannerSwitch.target = self
        ephemeralSettingsBannerSwitch.action = #selector(ephemeralSettingsBannerToggled)

        let menuBarCard = makeGroupedFormCard(
            rows: [
                makeGroupedFormCardRow(
                    "Menu bar quit reminder", control: menuBarQuitSwitch,
                    info: Self.menuBarQuitReminderInfo),
                // The note explains this row alone, so it rides under it
                // rather than under the card.
                GroupedFormNotedRow(
                    makeGroupedFormCardRow(
                        "Duplicate machine ID question", control: duplicateIDQuestionSwitch,
                        info: Self.duplicateMachineIDQuestionInfo),
                    notes: [duplicateIDQuestionNote]),
                makeGroupedFormCardRow(
                    EphemeralModeCopy.settingsReminderLabel, control: ephemeralSettingsBannerSwitch,
                    info: EphemeralModeCopy.settingsReminderParagraphs),
            ])

        // The governing control of the Virtual Machine Reminders section, so it
        // heads that section rather than sitting with the app reminders above.
        let agentInstallCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow(
                "Guest agent install reminder", control: agentInstallSwitch,
                info: Self.agentInstallReminderInfo)
        ])

        // Per-VM reminders: rebuilt on every appear (VMs may be added or removed).
        // Indented beneath the switch that governs them, the alignment Apple's
        // guidance uses to show a control's subordinates.
        vmSection.orientation = .vertical
        vmSection.alignment = .leading
        vmSection.spacing = Spacing.none
        vmSection.translatesAutoresizingMaskIntoConstraints = false
        let vmGroup = makeGroupedFormIndented(vmSection)

        let resetButton = NSButton(
            title: "Reset All Reminders", target: self, action: #selector(resetAllReminders))
        resetButton.bezelStyle = .push
        resetButton.controlSize = .small
        resetButton.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [
            makeGroupedFormSectionHeader("App Reminders"),
            menuBarCard,
            makeGroupedFormSectionHeader("Virtual Machine Reminders"),
            agentInstallCard,
            vmGroup,
            resetButton,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Spacing.small
        content.setCustomSpacing(Spacing.section, after: menuBarCard)
        content.setCustomSpacing(Spacing.section, after: vmGroup)

        // Full-width members. The reset button is excluded so it hugs its
        // intrinsic width at the leading edge.
        for member in [menuBarCard, agentInstallCard, vmGroup] {
            member.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        // Scroll when the VM list grows past the cap; hug content when short.
        let scrollView = makeGroupedFormScrollView(
            documentView: content, topInset: Spacing.large, bottomInset: Spacing.large)

        // Flash-only (no chevron/fade overlays): this scroll view *is* the pane's
        // root, so it has no superview of its own to host them until the tab view
        // adopts it. The window follows the content only up to the height cap,
        // so content that grows past it while the pane is on screen — a VM
        // added, the override caption appearing — overflows in place; the flash
        // is what says so.
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
        let heightCap = scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 0)
        self.heightCap = heightCap
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: SettingsPaneMetrics.width),
            hugHeight,
        ])
        view = SettingsPaneRootView(content: scrollView)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Publishes the pane's size, clamped by the height cap.
        refreshVMRows()
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
                _ = viewModel.menuBarQuitReminderDismissed
                _ = viewModel.duplicateMachineIDQuestionDismissed
                _ = viewModel.ephemeralSettingsBannerDismissed
                for instance in viewModel.instances {
                    _ = instance.id
                    _ = instance.name
                    _ = instance.hostState.agentInstallNudgeDismissed
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

    /// Publishes the pane's size for the window to follow.
    private func publishSize() {
        let window = view.window
        let maxHeight = visibleFrame(window).map { SettingsPaneMetrics.maxHeight(in: window, visibleFrame: $0) }
        if let maxHeight { heightCap?.constant = maxHeight }
        heightCap?.isActive = maxHeight != nil
        publishSettingsPaneSize(layoutHeight: maxHeight ?? SettingsPaneMetrics.width)
    }

    /// Re-arms the flash for a fresh appearance, so arriving at an overflowing
    /// pane cues every visit rather than only the first.
    func rearmScrollMoreCue() {
        rearmScrollFlash()
    }

    /// Re-arms the "more below" scroller flash after the pane's content height
    /// changes while it is on screen.
    ///
    /// The window follows the content only up to the pane's height cap, so
    /// content that grows past it overflows with nothing else to say so. Layout
    /// has to settle first: overflow is measured against the document's real
    /// height, and an un-laid-out subtree still reports the old one.
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
    /// VM the reminder applies to, or an empty-state caption when none does.
    private func rebuildVMRows() {
        for view in vmSection.arrangedSubviews {
            vmSection.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        vmSwitches.removeAll()

        let reminded = viewModel.instances.filter {
            VMConfigurationKeyRegistry.agentInstallReminder.applies($0.configuration)
        }
        guard !reminded.isEmpty else {
            let empty = makeGroupedFormContentText("No macOS virtual machines yet.")
            addGroupedFormFullWidth(empty, to: vmSection)
            return
        }

        var rows: [NSView] = []
        for instance in reminded {
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = #selector(vmReminderToggled(_:))
            let row = makeGroupedFormCardRow(instance.name, control: toggle)
            vmSwitches.append((instance, toggle))
            rows.append(row)
        }

        let card = makeGroupedFormCard(rows: rows, notes: [vmOverrideCaption])
        addGroupedFormFullWidth(card, to: vmSection)
    }

    /// Mirrors every switch to current state — ON when the reminder is shown
    /// (its dismissed flag is `false`).
    ///
    /// A per-VM row keeps showing what its VM reverts to while the app-wide
    /// install reminder is off; it just can't be changed until that goes back on.
    private func refreshSwitches() {
        menuBarQuitSwitch.state = viewModel.menuBarQuitReminderDismissed ? .off : .on
        duplicateIDQuestionSwitch.state = viewModel.duplicateMachineIDQuestionDismissed ? .off : .on
        applyGroupedFormRowEnabled(
            preferences.allowsDuplicateMachineIDOverride, control: duplicateIDQuestionSwitch)
        duplicateIDQuestionNote.refresh()
        ephemeralSettingsBannerSwitch.state = viewModel.ephemeralSettingsBannerDismissed ? .off : .on
        let overridden = viewModel.agentInstallPromptDisabled
        agentInstallSwitch.state = overridden ? .off : .on

        let hasVMs = !vmSwitches.isEmpty
        let wasShowingOverrideCaption = !vmOverrideCaption.isHidden
        vmOverrideCaption.refresh()

        for (instance, toggle) in vmSwitches {
            toggle.state = instance.hostState.agentInstallNudgeDismissed ? .off : .on
            applyGroupedFormRowEnabled(!overridden, control: toggle)
        }
        publishSize()

        // The override caption is a note of the per-VM card, so it changes the
        // pane's height only while that card exists.
        if hasVMs, wasShowingOverrideCaption != overridden { rearmScrollFlash() }
    }

    // MARK: - Info

    private static var menuBarQuitReminderInfo: [InfoPopoverParagraph] {
        InfoPopoverParagraph.message(
            title: MenuBarQuitReminderViewController.title, text: MenuBarQuitReminderViewController.text)
            + [.body("Shown when you quit (⌘Q).")]
    }

    private static var duplicateMachineIDQuestionInfo: [InfoPopoverParagraph] {
        let question = DuplicateMachineIDQuestion.prompt(verb: nil, names: nil)
        return InfoPopoverParagraph.message(title: question.title, text: question.message) + [
            .body(
                "Asked while Offer to start duplicate machine IDs anyway is on in Advanced. With this "
                    + "off, or once you choose Don\u{2019}t ask again on the question, Kernova starts "
                    + "the virtual machine without asking.")
        ]
    }

    private static var agentInstallReminderInfo: [InfoPopoverParagraph] {
        InfoPopoverParagraph.message(title: GuestAgentStatusViewController.title(for: .waiting), text: nil) + [
            .body(
                "The sidebar prompt to install the Kernova guest agent on a running macOS "
                    + "virtual machine. Turn a virtual machine off below to stop only its "
                    + "reminder. A virtual machine\u{2019}s reminder stops on its own once its "
                    + "agent is installed.")
        ]
    }

    @objc private func menuBarQuitToggled() {
        viewModel.menuBarQuitReminderDismissed = (menuBarQuitSwitch.state == .off)
    }

    @objc private func duplicateIDQuestionToggled() {
        viewModel.duplicateMachineIDQuestionDismissed = (duplicateIDQuestionSwitch.state == .off)
    }

    @objc private func ephemeralSettingsBannerToggled() {
        viewModel.ephemeralSettingsBannerDismissed = (ephemeralSettingsBannerSwitch.state == .off)
    }

    @objc private func agentInstallToggled() {
        viewModel.agentInstallPromptDisabled = (agentInstallSwitch.state == .off)
        refreshSwitches()
    }

    @objc private func vmReminderToggled(_ sender: NSSwitch) {
        guard let instance = vmSwitches.first(where: { $0.control === sender })?.instance else {
            Self.logger.log(.fault, "Toggled VM reminder switch not found in the rebuilt set")
            assertionFailure("Toggled VM reminder switch not found in the rebuilt set")
            return
        }
        if viewModel.setAgentInstallNudgeDismissed(sender.state == .off, for: instance) != .applied {
            refreshSwitches()
        }
    }

    @objc private func resetAllReminders() {
        Self.logger.log(.notice, "User reset all host reminders")
        viewModel.resetAllReminders()
        refreshSwitches()
    }
}
