import AppKit
import KernovaKit

/// The "Advanced" pane of the Settings window.
///
/// Hosts the *Always show advanced options* toggle — whether advanced menu
/// actions (e.g. *Start in Recovery Mode*) are always visible or revealed only
/// on an Option (⌥) hold — the two machine-identity toggles (blocking duplicate
/// machine IDs from booting, and whether Clone generates a new machine ID), and
/// the command-line tool install. The toggles are backed by `AppPreferences`;
/// the menus re-read the preferences each time they open, so no change
/// notification is needed here.
///
/// The tool section is absent, not disabled, in a build that resolves no
/// app-group container: the tool there could reach no app, so there is nothing
/// to offer.
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
                + "active. Apple documents running two VMs with the same machine ID at once as "
                + "undefined behavior.")

        let cloneCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow("Clones get a new machine ID", control: cloneNewIDSwitch)
        ])
        let cloneCaption = makeGroupedFormCaption(
            "A new machine ID gives each clone its own identity, so it can run alongside its "
                + "source. macOS 12 and earlier guests may not boot after their ID changes — "
                + "clone those keeping the ID. To do the opposite for one clone, hold Option (⌥) "
                + "over Clone in the Virtual Machine menu or the VM's context menu.")

        var rows: [NSView] = [
            makeGroupedFormSectionHeader("Advanced Options"),
            card,
            caption,
            makeGroupedFormSectionHeader("Machine Identity"),
            blockCard,
            blockCaption,
            cloneCard,
            cloneCaption,
        ]
        var fullWidthRows: [NSView] = [
            card, caption, blockCard, blockCaption, cloneCard, cloneCaption,
        ]
        // Absent, not disabled, in a build with no group container: the tool
        // installed from there could reach no app.
        let offersCommandLineTool = CommandLineToolInstaller.isAvailable
        if offersCommandLineTool {
            let installButton = NSButton(
                title: "Install\u{2026}", target: self, action: #selector(installCommandLineTool))
            installButton.bezelStyle = .push
            let toolCard = makeGroupedFormCard(rows: [
                makeGroupedFormCardRow("Command line tool", control: installButton)
            ])
            let toolCaption = makeGroupedFormCaption(
                "Links the bundled kernova tool into a folder you choose, so a shell can drive "
                    + "your virtual machines. Kernova has to be running for it to answer. If the "
                    + "folder is not already on your PATH, add it:")
            let pathHint = makeCalloutCode("export PATH=\"/usr/local/bin:$PATH\"")
            rows.append(contentsOf: [
                makeGroupedFormSectionHeader("Command Line Tool"), toolCard, toolCaption, pathHint,
            ])
            fullWidthRows.append(contentsOf: [toolCard, toolCaption, pathHint])
        }

        let section = NSStackView(views: rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = Spacing.small
        // Keep each caption tight to its card, but separate the groups so they
        // read as distinct settings.
        section.setCustomSpacing(Spacing.section, after: caption)
        section.setCustomSpacing(Spacing.section, after: blockCaption)
        if offersCommandLineTool {
            section.setCustomSpacing(Spacing.section, after: cloneCaption)
        }
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
        // Every card and caption spans the column; the section headers do not.
        var constraints = fullWidthRows.map {
            $0.widthAnchor.constraint(equalTo: section.widthAnchor)
        }
        constraints.append(contentsOf: [
            section.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            section.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            section.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            section.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            root.widthAnchor.constraint(equalToConstant: SettingsPaneMetrics.width),
        ])
        NSLayoutConstraint.activate(constraints)
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

    /// Asks where the tool should go, then links it there.
    ///
    /// A save panel rather than a hardcoded `/usr/local/bin`: the app is
    /// sandboxed, so the only way it can write outside its container is a path
    /// the user picks, and a panel is also what lets somebody choose a folder
    /// already on their `PATH`.
    @objc private func installCommandLineTool() {
        let panel = NSSavePanel()
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        panel.nameFieldStringValue = KernovaAppGroup.commandLineToolName
        panel.prompt = "Install"
        panel.message = "Choose where to install the kernova command line tool."
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.install(at: destination)
        }
    }

    private func install(at destination: URL) {
        do {
            try CommandLineToolInstaller.installSymlink(at: destination)
        } catch {
            presentInstallFailure(error, at: destination)
        }
    }

    /// Explains what stopped the install, keeping the equivalent command on
    /// screen and selectable so the user can run it themselves.
    private func presentInstallFailure(_ failure: any Error, at destination: URL) {
        let reason: String =
            switch failure {
            case CommandLineToolInstaller.InstallFailure.exists:
                "Something is already at that path. Kernova does not replace it."
            case CommandLineToolInstaller.InstallFailure.unwritable(let detail):
                detail
            default:
                failure.localizedDescription
            }

        let alert = NSAlert()
        alert.messageText = "Couldn\u{2019}t Install the Command Line Tool"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")

        let hint = NSStackView(views: [
            makeGroupedFormCaption("You can create the link yourself:"),
            makeCalloutCode(CommandLineToolInstaller.manualCommand(for: destination)),
        ])
        hint.orientation = .vertical
        hint.alignment = .leading
        hint.spacing = Spacing.tight
        hint.setFrameSize(hint.fittingSize)
        alert.accessoryView = hint

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
