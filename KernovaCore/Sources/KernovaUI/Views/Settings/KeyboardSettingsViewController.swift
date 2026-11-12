import AppKit
import KernovaCore
import KernovaLogging

/// The "Keyboard" pane of the Settings window: one row per ``ReservedShortcut``,
/// each naming its command and shortcut, with a switch that turns it on or off.
///
/// App-wide rather than per VM, because the shortcuts are the menu bar's.
@MainActor
final class KeyboardSettingsViewController: NSViewController, SettingsPaneContent {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "KeyboardSettingsViewController")

    static let sectionTitle = "Reserved Shortcuts"

    private let viewModel: VMLibraryViewModel

    /// Each shortcut's switch, in list order.
    private(set) var switches: [(shortcut: ReservedShortcut, control: NSSwitch)] = []

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Keyboard"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeyboardSettingsViewController does not support NSCoder")
    }

    /// What a shortcut's row explains: what it does on, then off.
    static func infoParagraphs(for shortcut: ReservedShortcut) -> [InfoPopoverParagraph] {
        let keys = shortcut.displayString
        return [
            .body(
                "On: \(keys) chooses Edit › \(shortcut.commandTitle) in every Kernova window, a virtual "
                    + "machine's screen included, whatever its Send system keys to guest setting. The guest "
                    + "never receives \(keys)."),
            .body("Off: the menu item has no shortcut, and a virtual machine's screen sends \(keys) to the guest."),
        ]
    }

    override func loadView() {
        switches = ReservedShortcut.allCases.map { shortcut in
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.target = self
            toggle.action = #selector(shortcutToggled(_:))
            return (shortcut, toggle)
        }
        let rows = switches.map { shortcut, toggle in
            let keys = makeGroupedFormValueLabel(shortcut.displayString)
            let control = NSStackView(views: [keys, toggle])
            control.orientation = .horizontal
            control.alignment = .centerY
            control.spacing = Spacing.standard
            return makeGroupedFormCardRow(
                shortcut.commandTitle, control: control, info: Self.infoParagraphs(for: shortcut))
        }
        let card = makeGroupedFormCard(rows: rows)

        let section = NSStackView(views: [makeGroupedFormSectionHeader(Self.sectionTitle), card])
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
            root.widthAnchor.constraint(equalToConstant: SettingsPaneMetrics.width),
            card.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        view = SettingsPaneRootView(content: root)
    }

    func refreshContent() {
        let disabled = viewModel.disabledReservedShortcuts
        for (shortcut, toggle) in switches {
            toggle.state = disabled.contains(shortcut) ? .off : .on
        }
        publishSettingsPaneSize()
    }

    @objc private func shortcutToggled(_ sender: NSSwitch) {
        guard let shortcut = switches.first(where: { $0.control === sender })?.shortcut else {
            Self.logger.log(.fault, "Toggled shortcut switch is not one of the pane's")
            assertionFailure("Toggled shortcut switch is not one of the pane's")
            return
        }
        viewModel.setReservedShortcut(shortcut, isOn: sender.state == .on)
    }
}
