import AppKit
import KernovaKit
import KernovaLogging

/// The "Advanced" pane of the Settings window.
///
/// Hosts the *Always show advanced options* toggle — whether advanced menu
/// actions (e.g. *Start in Recovery Mode*) are always visible or revealed only
/// on an Option (⌥) hold — the machine-identity settings (blocking duplicate
/// machine IDs from booting, and what Clone makes: a New Machine or an Exact
/// Copy), and
/// the command-line tool's two installs — the symlink, and a shell's completion
/// file. The toggles are backed by `AppPreferences`;
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
    private let duplicateIDOverrideSwitch = NSSwitch()
    private let cloneOutcomePopUp = NSPopUpButton()

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

        duplicateIDOverrideSwitch.controlSize = .small
        duplicateIDOverrideSwitch.target = self
        duplicateIDOverrideSwitch.action = #selector(duplicateIDOverrideToggled)

        cloneOutcomePopUp.controlSize = .small
        for outcome in CloneOutcome.allCases {
            cloneOutcomePopUp.addItem(withTitle: outcome.displayName)
            cloneOutcomePopUp.lastItem?.representedObject = outcome.rawValue
        }
        cloneOutcomePopUp.target = self
        cloneOutcomePopUp.action = #selector(cloneOutcomeChosen)

        let optionsCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow(
                "Always show advanced options", control: alwaysShowSwitch,
                info: [
                    .body(
                        "Advanced actions such as Start in Recovery Mode appear in a virtual "
                            + "machine's context menu while you hold Option (⌥). With this on, they "
                            + "always appear.")
                ])
        ])

        let identityCard = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow(
                "Offer to start duplicate machine IDs anyway", control: duplicateIDOverrideSwitch,
                info: [
                    .body(
                        "Kernova never starts a virtual machine while another with the same machine "
                            + "ID is active. Turn this on to be asked each time whether to start it "
                            + "anyway."),
                    .body(
                        "Apple documents running two virtual machines at once with the same "
                            + "identifier as undefined behavior in the guest operating system."),
                ]),
            makeGroupedFormCardRow(
                "Clone as", control: cloneOutcomePopUp,
                info: [
                    .body(
                        "A New Machine gets its own machine ID and MAC address, so it can run "
                            + "alongside its source. An Exact Copy keeps both, so the two are the same "
                            + "machine to their guests and networks: each is marked as sharing the "
                            + "other\u{2019}s MAC address, they never run on the same network at once, "
                            + "and they run at once only when you start one anyway."),
                    .body(
                        "An Exact Copy also carries its source\u{2019}s snapshots, Ephemeral Mode and "
                            + "display preferences, but not start at launch; a New Machine starts "
                            + "with none of these."),
                    .body(
                        "Where a virtual machine offers both, the second Clone item in the Virtual "
                            + "Machine menu, or Option (⌥) over Clone in its context menu, makes the "
                            + "other for one clone."),
                ]),
        ])

        var rows: [NSView] = [
            makeGroupedFormSectionHeader("Advanced Options"),
            optionsCard,
            makeGroupedFormSectionHeader("Machine Identity"),
            identityCard,
        ]
        var cards: [NSView] = [optionsCard, identityCard]
        // Absent, not disabled, in a build with no group container: the tool
        // installed from there could reach no app.
        if CommandLineToolInstaller.isAvailable {
            let installButton = NSButton(
                title: "Install\u{2026}", target: self, action: #selector(installCommandLineTool))
            installButton.bezelStyle = .push
            let toolCard = makeGroupedFormCard(rows: [
                makeGroupedFormCardRow(
                    "Command line tool", control: installButton,
                    info: [
                        .body(
                            "Links this copy's kernova tool into a folder you choose, so a shell can "
                                + "drive your virtual machines. The tool drives the copy of Kernova it "
                                + "links into, starting it when it isn't running."),
                        .body("If the folder isn't on your PATH, add it:"),
                        .code("export PATH=\"/usr/local/bin:$PATH\""),
                    ]),
                makeGroupedFormCardRow(
                    "Shell completions", control: makeCompletionsButton(),
                    info: [
                        .body(
                            "Writes a small file that loads completions from the tool itself, so "
                                + "they stay current as Kernova updates. Tab then completes verbs and "
                                + "flags, and your own virtual machines, snapshots, and setting keys."),
                        .body(
                            "bash needs the bash-completion package; the bash macOS ships is too old "
                                + "for it."),
                        .body("If the folder isn't on your fpath, add it to your ~/.zshrc:"),
                        .code("fpath=(~/.zsh/completions $fpath)"),
                    ]),
            ])
            rows.append(contentsOf: [makeGroupedFormSectionHeader("Command Line Tool"), toolCard])
            cards.append(toolCard)
        }

        let section = NSStackView(views: rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = Spacing.small
        // Separate the sections; a header stays tight to its card.
        for card in cards.dropLast() {
            section.setCustomSpacing(Spacing.section, after: card)
        }
        section.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(section)
        let pad = Spacing.large
        // Every card spans the column; the section headers do not.
        var constraints = cards.map {
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
        view = SettingsPaneRootView(content: root)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        publishSettingsPaneSize()
        alwaysShowSwitch.state = preferences.alwaysShowAdvancedOptions ? .on : .off
        duplicateIDOverrideSwitch.state = preferences.allowsDuplicateMachineIDOverride ? .on : .off
        cloneOutcomePopUp.selectItem(at: CloneOutcome.allCases.firstIndex(of: preferences.cloneOutcome) ?? 0)
    }

    @objc private func alwaysShowToggled() {
        preferences.alwaysShowAdvancedOptions = (alwaysShowSwitch.state == .on)
    }

    @objc private func duplicateIDOverrideToggled() {
        preferences.allowsDuplicateMachineIDOverride = (duplicateIDOverrideSwitch.state == .on)
    }

    @objc private func cloneOutcomeChosen() {
        guard let raw = cloneOutcomePopUp.selectedItem?.representedObject as? String,
            let outcome = CloneOutcome(rawValue: raw)
        else { return }
        preferences.cloneOutcome = outcome
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

    /// Links the tool at `destination`, first asking before a link that drives
    /// another copy of Kernova is pointed at this one: the panel's replace
    /// prompt names the file, not the copy every shell using it drives after.
    private func install(at destination: URL) {
        guard case .anotherCopysLink(let app) = CommandLineToolInstaller.occupant(at: destination)
        else {
            link(at: destination)
            return
        }
        guard let window = view.window else { return }
        presentSheetAlert(
            AlertConfiguration(
                title: "Point kernova at This Copy of Kernova?",
                message: "The kernova at \(destination.path) drives the copy of Kernova at "
                    + "\(app.path). Pointing it here makes it drive this copy, at "
                    + "\(Bundle.main.bundleURL.path), instead.",
                buttons: [
                    AlertButton("Point Here", role: .default) { [weak self] in
                        self?.link(at: destination)
                    },
                    AlertButton("Cancel", role: .cancel),
                ]),
            in: window)
    }

    private func link(at destination: URL) {
        do {
            try CommandLineToolInstaller.installSymlink(at: destination)
        } catch {
            presentInstallFailure(
                error, titled: "Couldn't Install the Command Line Tool",
                offering: "You can create the link yourself:",
                command: CommandLineToolInstaller.manualCommand(for: destination))
        }
    }

    /// The Install… menu that picks which shell to write completions for.
    ///
    /// A pull-down rather than three buttons or a shell picker beside one: the
    /// choice *is* the command, and nothing here has a state to remember. Each
    /// item carries its own target and action, so what was chosen is the sender
    /// rather than a selection a pull-down never really holds.
    private func makeCompletionsButton() -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .push
        // A pull-down's first item is the button's own title and is never
        // chosen.
        button.addItem(withTitle: "Install\u{2026}")
        for shell in ShellCompletionInstaller.Shell.allCases {
            let item = NSMenuItem(
                title: shell.rawValue, action: #selector(installShellCompletions(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = shell
            button.menu?.addItem(item)
        }
        return button
    }

    /// Asks where the chosen shell's completion file should go, then writes it.
    ///
    /// One panel per shell, because the grant a panel mints covers the one file
    /// it returned: writing three would need three answers whichever way they
    /// were gathered.
    @objc private func installShellCompletions(_ sender: NSMenuItem) {
        guard let shell = sender.representedObject as? ShellCompletionInstaller.Shell else {
            #log(
                Self.logger, .fault,
                "Shell completions item '\(sender.title, privacy: .public)' names no shell")
            assertionFailure("Shell completions item \(sender.title) names no shell")
            return
        }

        let directory = shell.defaultDirectory
        let panel = NSSavePanel()
        // The panel ignores a directory that is not there and opens wherever it
        // was last, so it lands on the closest folder that exists and the
        // message says where the file belongs — New Folder makes the rest.
        panel.directoryURL = ShellCompletionInstaller.existingAncestor(of: directory)
        panel.nameFieldStringValue = shell.fileName
        panel.prompt = "Install"
        panel.message =
            "\(shell.rawValue) completions belong at "
            + "\(directory.appending(path: shell.fileName).path(percentEncoded: false)). "
            + "New Folder creates a folder that is not there yet."
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.installCompletions(shell, at: destination)
        }
    }

    private func installCompletions(_ shell: ShellCompletionInstaller.Shell, at destination: URL) {
        do {
            try ShellCompletionInstaller.install(shell, at: destination)
        } catch {
            presentInstallFailure(
                error, titled: "Couldn't Install the Shell Completions",
                offering: "You can write the file yourself:",
                command: ShellCompletionInstaller.manualCommand(for: shell, at: destination))
        }
    }

    /// Explains what stopped an install, keeping the equivalent command on
    /// screen and selectable so the user can run it themselves.
    private func presentInstallFailure(
        _ failure: any Error, titled title: String, offering lead: String, command: String
    ) {
        let hint = NSStackView(views: [
            makeGroupedFormContentText(lead),
            makeCalloutCode(command),
        ])
        hint.orientation = .vertical
        hint.alignment = .leading
        hint.spacing = Spacing.tight
        hint.setFrameSize(hint.fittingSize)

        guard let window = view.window else { return }
        presentSheetAlert(
            .acknowledgement(
                title: title, message: Self.reason(for: failure), accessoryView: hint),
            in: window)
    }

    /// What an install failure says on screen.
    private static func reason(for failure: any Error) -> String {
        switch failure {
        case InstallFailure.exists:
            "Something is already at that path. Kernova does not replace it."
        case InstallFailure.unwritable(let detail):
            detail
        default:
            failure.localizedDescription
        }
    }

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "AdvancedSettingsViewController")
}
