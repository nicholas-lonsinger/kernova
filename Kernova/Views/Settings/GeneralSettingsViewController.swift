import AppKit
import ServiceManagement

/// The "General" pane of the Settings window.
///
/// Hosts the *Open at Login* toggle, backed by `SMAppService.mainApp` through
/// `LoginItemService`. `.status` is the source of truth (never persisted): the
/// switch is synced from it on appear and whenever the app regains focus, so a
/// change made in System Settings → Login Items is reflected without a restart.
@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let loginItem: LoginItemService
    private let openAtLoginSwitch = NSSwitch()
    private var focusObserver: (any NSObjectProtocol)?

    init(loginItem: LoginItemService = .shared) {
        self.loginItem = loginItem
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

        let card = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Open at Login", control: openAtLoginSwitch)
        ])
        let caption = makeGroupedFormCaption(
            "Start Kernova automatically when you log in, so its virtual machines and clipboard "
                + "sharing are ready without opening a window. You can also manage this in System "
                + "Settings → General → Login Items & Extensions.")

        let section = NSStackView(views: [
            makeGroupedFormSectionHeader("General"),
            card,
            caption,
        ])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = Spacing.small
        section.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(section)
        let pad = Spacing.large
        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            section.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            section.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            section.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            root.widthAnchor.constraint(equalToConstant: 520),
            card.widthAnchor.constraint(equalTo: section.widthAnchor),
            caption.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
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
}
