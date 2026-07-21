import AppKit
import os

/// The "Reminders" pane of the Settings window.
///
/// Surfaces every host-side reminder Kernova can suppress, with a switch to turn
/// each back on, plus a *Reset All Reminders* action. Each switch's polarity is
/// **ON = the reminder is shown** (its dismissed flag is `false`), matching the
/// VM Settings pane's "Show install reminder" toggle.
///
/// Three reminders are represented:
/// - *Menu Bar Quit Reminder* and *Enable File Sharing Reminder* — app-wide,
///   backed by `AppPreferences`.
/// - one row per VM for the *guest-agent install nudge* — per-VM, backed by each
///   VM's bundle configuration and written through
///   `VMLibraryViewModel.setAgentInstallNudgeDismissed(_:for:)`.
///
/// The guest agent surfaces its own File Provider reminder *inside* a VM from a
/// separate defaults domain in a separate process; that dismissal is out of
/// reach from the host and is called out to the user in a trailing caption
/// rather than silently ignored.
///
/// Follows the repo's read-on-appear / write-on-action idiom (no live
/// observation): `viewWillAppear()` rebuilds the per-VM rows from
/// `viewModel.instances` and refreshes every switch from current state.
@MainActor
final class RemindersSettingsViewController: NSViewController {
    private static let logger = Logger(subsystem: "app.kernova", category: "RemindersSettingsViewController")

    /// Fixed pane width, matching the General/Advanced panes.
    private static let paneWidth: CGFloat = 520
    /// Height at which the pane stops growing and starts scrolling — keeps a
    /// long VM list from making the Settings window unreasonably tall.
    private static let maxPaneHeight: CGFloat = 520

    private let preferences: AppPreferences
    private let viewModel: VMLibraryViewModel

    private let menuBarQuitSwitch = NSSwitch()
    private let fileProviderSwitch = NSSwitch()

    /// The persistent container in the content stack that holds either the
    /// per-VM card or the empty-state caption, rebuilt on every appear.
    private let vmSection = NSStackView()
    /// The live per-VM switches, paired with their VM, rebuilt on every appear.
    private var vmSwitches: [(instance: VMInstance, control: NSSwitch)] = []

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

        fileProviderSwitch.controlSize = .small
        fileProviderSwitch.target = self
        fileProviderSwitch.action = #selector(fileProviderToggled)

        // App-wide reminders: one card, two hairline-separated rows.
        let appCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Menu Bar Quit Reminder", control: menuBarQuitSwitch),
            makeGroupedFormCardRow("Enable File Sharing Reminder", control: fileProviderSwitch),
        ])
        let appMenuCaption = makeGroupedFormCaption(
            "The Menu Bar Quit Reminder appears when you quit (⌘Q) and Kernova keeps running in the "
                + "menu bar, reminding you it — and your virtual machines — are still going.")
        let appFileCaption = makeGroupedFormCaption(
            "The Enable File Sharing Reminder appears when clipboard file sharing needs to be turned "
                + "on for Kernova in System Settings.")

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

        let guestGapCaption = makeGroupedFormCaption(
            "Reminders shown inside a virtual machine by the Kernova guest agent are managed "
                + "separately, within that virtual machine, and aren't affected here.")

        let content = NSStackView(views: [
            makeGroupedFormSectionHeader("App Reminders"),
            appCard,
            appMenuCaption,
            appFileCaption,
            makeGroupedFormSectionHeader("Virtual Machine Reminders"),
            vmSection,
            vmCaption,
            resetButton,
            resetCaption,
            guestGapCaption,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Spacing.small
        // Separate each logical group so they read as distinct blocks, matching
        // the General pane's rhythm.
        content.setCustomSpacing(Spacing.section, after: appFileCaption)
        content.setCustomSpacing(Spacing.section, after: vmCaption)
        content.setCustomSpacing(Spacing.section, after: resetCaption)

        // Full-width members (cards and wrapping captions). The reset button is
        // intentionally excluded so it hugs its intrinsic width at the leading edge.
        for member in [appCard, appMenuCaption, appFileCaption, vmSection, vmCaption, resetCaption, guestGapCaption] {
            member.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        // Scroll when the VM list grows past the cap; hug content when short.
        let scrollView = makeGroupedFormScrollView(
            documentView: content, topInset: Spacing.large, bottomInset: Spacing.large)
        // Let the pane's size flow from its content (see the General/Advanced
        // panes for why the root must not use autoresizing-mask constraints).
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let hugHeight = scrollView.heightAnchor.constraint(
            equalTo: content.heightAnchor, constant: Spacing.large * 2)
        hugHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: Self.paneWidth),
            hugHeight,
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maxPaneHeight),
        ])
        view = scrollView
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebuildVMRows()
        refreshSwitches()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Drive NSTabViewController's per-tab window resize from the measured
        // fitting height (clamped by the height cap), so switching to this tab
        // animates to the right size — the scroll view otherwise masks the
        // document's intrinsic height.
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
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
        fileProviderSwitch.state = preferences.fileProviderReminderDismissed ? .off : .on
        for (instance, toggle) in vmSwitches {
            toggle.state = instance.configuration.agentInstallNudgeDismissed ? .off : .on
        }
    }

    @objc private func menuBarQuitToggled() {
        preferences.menuBarQuitReminderDismissed = (menuBarQuitSwitch.state == .off)
    }

    @objc private func fileProviderToggled() {
        preferences.fileProviderReminderDismissed = (fileProviderSwitch.state == .off)
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
