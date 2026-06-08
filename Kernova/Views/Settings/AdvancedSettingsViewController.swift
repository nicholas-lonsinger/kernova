import AppKit

/// The "Advanced" pane of the Settings window.
///
/// Today it hosts a single toggle — *Always show advanced options* — which
/// controls whether advanced menu actions (e.g. *Start in Recovery Mode*) are
/// always visible or revealed only on an Option (⌥) hold. Backed by
/// `AppPreferences`; the menus re-read the preference each time they open, so no
/// change notification is needed here.
@MainActor
final class AdvancedSettingsViewController: NSViewController {
    private let preferences: AppPreferences
    private let alwaysShowSwitch = NSSwitch()

    init(preferences: AppPreferences = .shared) {
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        title = "Advanced"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AdvancedSettingsViewController does not support NSCoder")
    }

    override func loadView() {
        alwaysShowSwitch.controlSize = .small
        alwaysShowSwitch.target = self
        alwaysShowSwitch.action = #selector(alwaysShowToggled)

        let card = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Always show advanced options", control: alwaysShowSwitch)
        ])
        let caption = makeGroupedFormCaption(
            "Advanced actions such as Start in Recovery Mode are normally revealed by holding the "
                + "Option (⌥) key in menus. Turn this on to always show them.")

        let section = NSStackView(views: [
            makeGroupedFormSectionHeader("Advanced Options"),
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
        alwaysShowSwitch.state = preferences.alwaysShowAdvancedOptions ? .on : .off
    }

    @objc private func alwaysShowToggled() {
        preferences.alwaysShowAdvancedOptions = (alwaysShowSwitch.state == .on)
    }
}
