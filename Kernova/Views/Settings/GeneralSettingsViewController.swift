import AppKit
import ServiceManagement

/// The "General" pane of the Settings window.
///
/// Hosts two app-lifecycle toggles:
/// - *Open at Login*, backed by `SMAppService.mainApp` through
///   `LoginItemService`. `.status` is the source of truth (never persisted): the
///   switch is synced from it on appear and whenever the app regains focus, so a
///   change made in System Settings → Login Items is reflected without a restart.
/// - *Continue running in Status Bar*, backed by `AppPreferences` through the
///   view model's observable mirror. Governs whether a GUI-origin quit (⌘Q) or a
///   last-window close leaves Kernova resident in the status bar, or quits the
///   app outright.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let loginItem: LoginItemService
    private let viewModel: VMLibraryViewModel
    private let openAtLoginSwitch = NSSwitch()
    private let keepInMenuBarSwitch = NSSwitch()
    private var focusObserver: (any NSObjectProtocol)?

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

        let loginCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Open at Login", control: openAtLoginSwitch)
        ])
        let loginCaption = makeGroupedFormCaption(
            "Open Kernova automatically when you log in. With Continue running in "
                + "Status Bar on, it opens in the Status Bar with no window.")
        let openLoginItemsButton = NSButton(
            title: "Open Login Items Settings…", target: self,
            action: #selector(openLoginItemsSettings))
        openLoginItemsButton.bezelStyle = .push
        openLoginItemsButton.controlSize = .small
        openLoginItemsButton.setContentHuggingPriority(.required, for: .horizontal)

        let menuBarCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Continue running in Status Bar", control: keepInMenuBarSwitch)
        ])
        let menuBarCaption = makeGroupedFormCaption(
            "Quitting (⌘Q) or closing all windows will keep Kernova running in the Status Bar. To "
                + "fully quit, either Quit directly from the Status Icon or with Quit Kernova "
                + "(⌥⌘Q). With this off, Kernova has no Status Bar icon and quits when you close "
                + "its last window.")

        let section = NSStackView(views: [
            makeGroupedFormSectionHeader("General"),
            loginCard,
            loginCaption,
            openLoginItemsButton,
            menuBarCard,
            menuBarCaption,
        ])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = Spacing.small
        // Keep each caption tight to its card, but separate the two card+caption
        // groups so they read as distinct settings.
        section.setCustomSpacing(Spacing.section, after: openLoginItemsButton)
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
            loginCard.widthAnchor.constraint(equalTo: section.widthAnchor),
            loginCaption.widthAnchor.constraint(equalTo: section.widthAnchor),
            menuBarCard.widthAnchor.constraint(equalTo: section.widthAnchor),
            menuBarCaption.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Drive NSTabViewController's per-tab window resize from the measured
        // fitting height. Without this the window keeps whatever height it
        // already has (e.g. a stale tall autosaved frame), and the four-edge
        // section pin stretches the cards over the excess.
        preferredContentSize = view.fittingSize
        keepInMenuBarSwitch.state = viewModel.keepInMenuBarOnQuit ? .on : .off
        refreshFromStatus()
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

    /// Mirrors the switch to the live `SMAppService` status (the source of truth).
    private func refreshFromStatus() {
        openAtLoginSwitch.state = loginItem.isEnabled ? .on : .off
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
