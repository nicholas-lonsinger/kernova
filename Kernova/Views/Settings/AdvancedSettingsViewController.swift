import AppKit

/// The "Advanced" pane of the Settings window.
///
/// Hosts the *Always show advanced options* toggle — whether advanced menu
/// actions (e.g. *Start in Recovery Mode*) are always visible or revealed only
/// on an Option (⌥) hold — and the two machine-identity toggles: blocking
/// duplicate machine IDs from booting, and whether Clone generates a new
/// machine ID. All backed by `AppPreferences`; the menus re-read the
/// preferences each time they open, so no change notification is needed here.
@MainActor
final class AdvancedSettingsViewController: NSViewController {
    private let preferences: AppPreferences
    private let alwaysShowSwitch = NSSwitch()
    private let blockDuplicateIDSwitch = NSSwitch()
    private let cloneNewIDSwitch = NSSwitch()

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

        blockDuplicateIDSwitch.controlSize = .small
        blockDuplicateIDSwitch.target = self
        blockDuplicateIDSwitch.action = #selector(blockDuplicateIDToggled)

        cloneNewIDSwitch.controlSize = .small
        cloneNewIDSwitch.target = self
        cloneNewIDSwitch.action = #selector(cloneNewIDToggled)

        let card = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Always show advanced options", control: alwaysShowSwitch)
        ])
        let caption = makeGroupedFormCaption(
            "Advanced actions such as Start in Recovery Mode are normally revealed by holding the "
                + "Option (⌥) key in menus. Turn this on to always show them.")

        let blockCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Block duplicate machine IDs from booting", control: blockDuplicateIDSwitch)
        ])
        let blockCaption = makeGroupedFormCaption(
            "Refuses to start a virtual machine while another VM with the same machine ID is "
                + "running. Two VMs sharing a machine ID must never run at once — doing so is "
                + "undefined behavior and can corrupt both.")

        let cloneCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Clones get a new machine ID", control: cloneNewIDSwitch)
        ])
        let cloneCaption = makeGroupedFormCaption(
            "A new machine ID gives each clone its own identity, so it can run alongside its "
                + "source. Keeping the same ID preserves the guest's activation state — macOS 12 "
                + "and earlier guests may not boot after their ID changes. Hold Option (⌥) on "
                + "Clone to do the opposite of this setting for one clone.")

        let section = NSStackView(views: [
            makeGroupedFormSectionHeader("Advanced Options"),
            card,
            caption,
            makeGroupedFormSectionHeader("Machine Identity"),
            blockCard,
            blockCaption,
            cloneCard,
            cloneCaption,
        ])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = Spacing.small
        // Keep each caption tight to its card, but separate the groups so they
        // read as distinct settings.
        section.setCustomSpacing(Spacing.section, after: caption)
        section.setCustomSpacing(Spacing.section, after: blockCaption)
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
            caption.widthAnchor.constraint(equalTo: section.widthAnchor),
            blockCard.widthAnchor.constraint(equalTo: section.widthAnchor),
            blockCaption.widthAnchor.constraint(equalTo: section.widthAnchor),
            cloneCard.widthAnchor.constraint(equalTo: section.widthAnchor),
            cloneCaption.widthAnchor.constraint(equalTo: section.widthAnchor),
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
        alwaysShowSwitch.state = preferences.alwaysShowAdvancedOptions ? .on : .off
        blockDuplicateIDSwitch.state = preferences.blockDuplicateMachineIDBoot ? .on : .off
        cloneNewIDSwitch.state = preferences.cloneGeneratesNewMachineID ? .on : .off
    }

    @objc private func alwaysShowToggled() {
        preferences.alwaysShowAdvancedOptions = (alwaysShowSwitch.state == .on)
    }

    @objc private func blockDuplicateIDToggled() {
        preferences.blockDuplicateMachineIDBoot = (blockDuplicateIDSwitch.state == .on)
    }

    @objc private func cloneNewIDToggled() {
        preferences.cloneGeneratesNewMachineID = (cloneNewIDSwitch.state == .on)
    }
}
