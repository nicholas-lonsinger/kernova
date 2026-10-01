import AppKit
import ServiceManagement

/// The "General" pane of the Settings window.
///
/// Hosts two app-lifecycle toggles:
/// - *Open at Login*, backed by `SMAppService.mainApp` through
///   `LoginItemService`. `.status` is the source of truth (never persisted): the
///   switch and its approval note are synced from it on appear and whenever the
///   app regains focus, so a change made in System Settings → Login Items is
///   reflected without a restart.
/// - *Continue running in the menu bar*, backed by `AppPreferences` through the
///   view model's observable mirror. Governs whether a GUI-origin quit (⌘Q) or a
///   last-window close leaves Kernova resident in the menu bar, or quits the
///   app outright.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let loginItem: LoginItemService
    private let viewModel: VMLibraryViewModel
    private let openAtLoginSwitch = NSSwitch()
    private let keepInMenuBarSwitch = NSSwitch()
    private var focusObserver: (any NSObjectProtocol)?
    /// Says the login item waits on the user while `SMAppService` reports it
    /// needs approval — the switch reads off until they give it.
    private lazy var loginApprovalNote = GroupedFormStateNote(
        "Needs approval in System Settings › General › Login Items.",
        shownWhen: { [unowned self] in loginItem.status == .requiresApproval })

    init(loginItem: LoginItemService = .shared, viewModel: VMLibraryViewModel) {
        self.loginItem = loginItem
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GeneralSettingsViewController does not support NSCoder")
    }

    override func loadView() {
        openAtLoginSwitch.controlSize = .small
        openAtLoginSwitch.target = self
        openAtLoginSwitch.action = #selector(openAtLoginToggled)

        keepInMenuBarSwitch.controlSize = .small
        keepInMenuBarSwitch.target = self
        keepInMenuBarSwitch.action = #selector(keepInMenuBarToggled)

        let openLoginItemsButton = NSButton(
            title: "Open Login Items Settings…", target: self,
            action: #selector(openLoginItemsSettings))
        openLoginItemsButton.bezelStyle = .push
        openLoginItemsButton.controlSize = .small
        openLoginItemsButton.setContentHuggingPriority(.required, for: .horizontal)

        let card = makeGroupedFormCard(rows: [
            GroupedFormNotedRow(
                makeGroupedFormCardRow(
                    "Open at Login", control: openAtLoginSwitch,
                    info: [
                        .body(
                            "With Continue running in the menu bar on, Kernova opens in the menu "
                                + "bar with no window.")
                    ]),
                notes: [loginApprovalNote]),
            makeGroupedFormCardRow(
                "Continue running in the menu bar", control: keepInMenuBarSwitch,
                info: [
                    .body(
                        "Quitting (⌘Q) or closing the last window leaves Kernova, and any running "
                            + "virtual machines, in the menu bar. To quit fully, choose Quit from the "
                            + "menu bar item or press ⌥⌘Q. With this off, Kernova has no menu bar "
                            + "item and quits when its last window closes.")
                ]),
        ])

        let section = NSStackView(views: [
            makeGroupedFormSectionHeader("General"),
            card,
            openLoginItemsButton,
        ])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = Spacing.small
        section.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        // Let the root's size flow from its content. Without this, NSTabViewController
        // frames the installed pane to the tab view's bounds via autoresizing-mask
        // constraints that both collide with the explicit width (the logged
        // "Conflicting constraints" warning) and stretch the four-edge-pinned section
        // to the tab view's height (the empty-card void).
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(section)
        let pad = Spacing.large
        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            section.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            section.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            section.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            root.widthAnchor.constraint(equalToConstant: SettingsPaneMetrics.width),
            card.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Drive NSTabViewController's per-tab window resize from the measured
        // fitting height. Without this the window keeps whatever height it
        // already has (e.g. a stale tall autosaved frame), and the four-edge
        // section pin stretches the cards over the excess.
        // Measured after the refresh, so a showing approval note counts.
        keepInMenuBarSwitch.state = viewModel.keepInMenuBarOnQuit ? .on : .off
        refreshFromStatus()
        preferredContentSize = view.fittingSize
        // Refresh when the app regains focus — e.g. returning from System Settings
        // after approving/toggling the login item there.
        if focusObserver == nil {
            focusObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // queue: .main guarantees main-thread delivery, so this is safe.
                MainActor.assumeIsolated { self?.refreshFromStatus() }
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let focusObserver {
            NotificationCenter.default.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    /// Mirrors the switch and the approval note to the live `SMAppService` status
    /// (the source of truth).
    private func refreshFromStatus() {
        openAtLoginSwitch.state = loginItem.isEnabled ? .on : .off
        loginApprovalNote.refresh()
    }

    @objc private func openAtLoginToggled() {
        let enable = openAtLoginSwitch.state == .on
        let status = loginItem.setEnabled(enable)
        // `.requiresApproval` means the user must flip Kernova on in System
        // Settings; deep-link there. `refreshFromStatus` then reflects the true
        // (not-yet-enabled) state rather than the optimistic switch position.
        if status == .requiresApproval {
            loginItem.openLoginItemsSettings()
        }
        refreshFromStatus()
    }

    @objc private func openLoginItemsSettings() {
        loginItem.openLoginItemsSettings()
    }

    @objc private func keepInMenuBarToggled() {
        // Through the view model's observable mirror, not `AppPreferences`
        // directly: `AppDelegate` creates and tears down the status item from an
        // observation of this property, which a bare `UserDefaults` write would
        // never wake.
        viewModel.keepInMenuBarOnQuit = (keepInMenuBarSwitch.state == .on)
    }
}
