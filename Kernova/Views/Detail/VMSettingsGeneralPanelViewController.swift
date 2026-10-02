import AppKit
import KernovaLogging

/// The General category: the VM's identity rows and its startup behavior.
@MainActor
final class VMSettingsGeneralPanelViewController: NSViewController, VMSettingsPanel,
    NSMenuItemValidation
{
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMSettingsGeneralPanel")

    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.general
    private var lockRegistry = VMSettingsLockRegistry()

    private let panelStack = NSStackView()

    init(context: VMSettingsPanelContext) {
        self.context = context
        self.nameLabel = InlineEditableLabel(
            text: context.instance.name, font: Typography.body, textColor: .labelColor,
            placeholder: "Name", controlsEnabled: false)
        super.init(nibName: nil, bundle: nil)
        wireNameLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsGeneralPanelViewController does not support NSCoder")
    }

    override func loadView() {
        panelStack.orientation = .vertical
        panelStack.alignment = .leading
        panelStack.spacing = Spacing.section
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        view = panelStack
    }

    // MARK: - Panel

    func rebuild() {
        loadViewIfNeeded()
        panelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockRegistry.removeAll()
        renderedAutoStartWarning = nil

        for section in [buildGeneralSection(), buildStartupSection()] {
            panelStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
        }
    }

    func refresh() {
        lockRegistry.apply(isReadOnly: isReadOnly)
        refreshGeneral()
        refreshStartup()
    }

    /// Commits an in-flight name rename for the outgoing instance while it is
    /// still bound: a rebuild drops the edit box without commit/cancel, which
    /// would lose the typed text and strand `activeRename` at the old id —
    /// re-selecting that VM would spontaneously reopen the box.
    func willRebind() {
        if isViewLoaded { nameLabel.endEditing() }
    }

    /// Ends an in-flight rename through the commit path (focus loss commits):
    /// an edit left armed would re-show the box on reappear against a stale
    /// marker.
    func prepareForDisappearance() {
        nameLabel.endEditing()
    }

    // General
    /// The name row's value, which doubles as its rename box.
    ///
    /// Built once and re-parented into each rebuilt row: the label owns the
    /// width cap that hugs the box to the name, so one built per `rebuild()`
    /// would leave the caps of every earlier build stacked on it.
    private let nameLabel: InlineEditableLabel
    /// The install-record row and its value label, hidden while the VM
    /// carries no record of the image it was set up from.
    private var installedImageRow: GroupedFormCollapsibleRow?
    private var installedImageValueLabel: NSTextField?
    /// The SHA-256 and Verification rows under it, hidden while that record
    /// carries no digest.
    private var digestRow: GroupedFormCollapsibleRow?
    private var digestValueLabel: NSTextField?
    private var digestCopyButton: CopyValueButton?
    private var verificationRow: GroupedFormCollapsibleRow?
    private var verificationValueLabel: NSTextField?
    /// The OS version row and its value label, hidden until an agent reports
    /// one; both `nil` for Linux guests, which have no agent to report one.
    private var guestOSVersionRow: GroupedFormCollapsibleRow?
    private var guestOSVersionValueLabel: NSTextField?
    /// The Machine ID row and its value label, hidden while the VM has no
    /// machine identifier.
    private var machineIDRow: GroupedFormCollapsibleRow?
    private var machineIDValueLabel: NSTextField?
    /// The Machine ID row's note naming the other VMs holding this one's
    /// machine ID, hidden while there are none.
    private var sharedMachineIDNote: GroupedFormStateNote?

    // Startup
    private var autoStartSwitch = NSSwitch()
    /// Holds the banner naming how many macOS guests are marked to start at
    /// launch, when that exceeds what macOS runs at once.
    private var autoStartWarningContainer = NSStackView()
    private var ephemeralSwitch = NSSwitch()
    private var ephemeralBaselinePopUp = NSPopUpButton()
    /// The Ephemeral Mode row and its Baseline snapshot sub-option, retained so
    /// the sub-option shows only while the mode is on.
    private var ephemeralGroup: GroupedFormSubOptionGroup?
    /// Explains that a baseline needs a snapshot first, while the VM has none.
    private var ephemeralNoSnapshotsCaption: GroupedFormStateNote?
    /// Names the state a shutdown comes to rest in, which the selected
    /// baseline's kind decides, while a baseline resolves.
    private var ephemeralBaselineCaption: GroupedFormStateNote?
    /// One entry of the Baseline snapshot menu, as rendered.
    private struct BaselineMenuItem: Equatable {
        let id: UUID
        let title: String
    }
    /// What the baseline menu was last built from, so it rebuilds exactly when
    /// the list or a rendered title changed rather than on every `apply()` pass.
    private var renderedEphemeralBaselines: [BaselineMenuItem]?

    /// The Startup capacity banner's rendered message, on the same terms.
    private var renderedAutoStartWarning: String?
    private var isRenaming: Bool {
        viewModel.activeRename == .detail(instance.id)
    }

    // MARK: General

    /// What the install-record row is called for `guestOS`.
    ///
    /// A macOS install ran to completion under Kernova, so its row names the
    /// version the VM started life at, sitting beside the "OS version" row that
    /// names what the guest reports today. A Linux ISO is only attached for the
    /// distribution's own installer to use — which can install something else,
    /// or nothing — so that row names the media and claims nothing about the
    /// outcome.
    static func installedImageRowLabel(guestOS: VMGuestOS) -> String {
        guestOS == .macOS ? "Installed version" : "Installer image"
    }

    /// Points the shared inline-edit machine at this pane's rename verbs.
    ///
    /// The closures read `instance` when they fire rather than capturing it, so
    /// a commit raised while the pane rebinds still lands on the outgoing VM.
    private func wireNameLabel() {
        nameLabel.alignment = .right
        // Right-click "Rename" too, matching the storage rows and sidebar (the
        // item is gated by `validateMenuItem` when the VM can't be renamed).
        let renameMenu = NSMenu()
        let renameItem = NSMenuItem(
            title: "Rename", action: #selector(startRename), keyEquivalent: "")
        renameItem.target = self
        renameMenu.addItem(renameItem)
        nameLabel.contextMenu = { renameMenu }
        // A click asks the model to open the rename; it comes back in through
        // `refreshGeneral`, which is the one place the box opens.
        nameLabel.onClicked = { [weak self] in self?.startRename() }
        nameLabel.currentText = { [weak self] in self?.instance.name }
        nameLabel.onEditCommitted = { [weak self] text, _ in
            guard let self else { return }
            self.viewModel.commitRename(for: self.instance, newName: text, from: .detail)
        }
        nameLabel.onEditCancelled = { [weak self] in
            guard let self else { return }
            self.viewModel.cancelRename(for: self.instance, from: .detail)
        }
    }

    private func buildGeneralSection() -> NSView {
        // The row's default trailing spacer absorbs the slack, so the label sits
        // at the trailing edge as a value and hugs the text as an edit box.
        var rows: [NSView] = [
            makeGroupedFormCardRow("Name", control: nameLabel),
            makeGroupedFormCardRow(
                "Type", control: makeGroupedFormValueLabel(instance.configuration.guestOS.displayName)),
            makeMachineIDRow(),
        ]
        // The install-record and OS rows are built whatever the VM knows today,
        // then hidden until it knows: an install completing or a first agent Hello fills one in
        // while this pane is on screen, and only `apply()` runs then.
        rows += makeInstallRecordRows()

        if instance.configuration.guestOS == .macOS {
            let reported = instance.guestOSVersionDisplay
            let versionLabel = makeGroupedFormValueLabel(reported ?? "")
            guestOSVersionValueLabel = versionLabel
            let versionRow = GroupedFormCollapsibleRow(
                row: makeGroupedFormCardRow("OS version", control: versionLabel))
            versionRow.isHidden = reported == nil
            guestOSVersionRow = versionRow
            rows.append(versionRow)
        } else {
            guestOSVersionValueLabel = nil
            guestOSVersionRow = nil
        }
        rows += [
            makeGroupedFormCardRow(
                "Boot mode", control: makeGroupedFormValueLabel(instance.configuration.bootMode.displayName)),
            makeGroupedFormCardRow(
                "Created",
                control: makeGroupedFormValueLabel(
                    instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))),
        ]
        refreshMachineID()
        return makeGroupedFormSection([lockRegistry.makeHeader("General"), makeGroupedFormCard(rows: rows)])
    }

    /// The Machine ID row, empty until `refreshMachineID()` fills it.
    private func makeMachineIDRow() -> NSView {
        let label = makeGroupedFormValueLabel("")
        label.font = .monospacedSystemFont(ofSize: Typography.body.pointSize, weight: .regular)
        machineIDValueLabel = label
        let note = GroupedFormStateNote(content: { [weak self] in self?.resolved.sharedMachineIDNote })
        sharedMachineIDNote = note
        let row = GroupedFormCollapsibleRow(
            row: GroupedFormNotedRow(makeGroupedFormCardRow("Machine ID", control: label), notes: [note]))
        machineIDRow = row
        return row
    }

    /// The install-record row and the digest rows under it, empty until
    /// `refreshInstallRecord()` fills them.
    private func makeInstallRecordRows() -> [NSView] {
        let installedLabel = makeGroupedFormValueLabel("")
        installedImageValueLabel = installedLabel
        let installedRow = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow(
                Self.installedImageRowLabel(guestOS: instance.configuration.guestOS),
                control: installedLabel))
        installedImageRow = installedRow

        let digestLabel = makeGroupedFormValueLabel("")
        digestLabel.font = .monospacedSystemFont(ofSize: Typography.body.pointSize, weight: .regular)
        digestValueLabel = digestLabel
        let copy = CopyValueButton(name: "Copy SHA-256")
        digestCopyButton = copy
        let digestControl = NSStackView(views: [digestLabel, copy])
        digestControl.orientation = .horizontal
        digestControl.spacing = Spacing.tight
        let digestRow = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow("SHA-256", control: digestControl))
        self.digestRow = digestRow

        let verificationLabel = makeGroupedFormValueLabel("")
        verificationValueLabel = verificationLabel
        let verificationRow = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow("Verification", control: verificationLabel))
        self.verificationRow = verificationRow

        refreshInstallRecord()
        return [installedRow, digestRow, verificationRow]
    }

    /// A SHA-256 shortened to its first and last eight hex digits, which is as
    /// much as anyone compares by eye.
    static func abbreviatedDigest(_ sha256: String) -> String {
        "\(sha256.prefix(8))\u{2026}\(sha256.suffix(8))"
    }

    /// Tooltip on the Verification row of a digest compared with nothing.
    static let uncheckedDigestToolTip =
        "Computed from the downloaded file. It wasn't compared with any checksum."

    // MARK: Startup

    /// The info paragraphs of the "Start when Kernova opens" row. The launch
    /// pass walks the library in sidebar order, so that is the order the marked
    /// VMs come up in.
    static let autoStartInfo: [InfoPopoverParagraph] = [
        .body(
            "Starts this virtual machine each time Kernova opens. A suspended virtual machine resumes from its saved state; one that has not finished its initial setup is left alone."
        ),
        .body("Virtual machines start in the order they appear in the sidebar."),
        .body("Turn on Open at Login in Settings → General to have it running after you log in."),
    ]

    /// The Startup card's two toggles, their notes, and the capacity banner's
    /// container.
    ///
    /// Not `lockable`: the auto-start flag is read once at app launch, the
    /// ephemeral one at power-off, and neither reaches a
    /// `VZVirtualMachineConfiguration` — so both edit while the VM runs.
    private func buildStartupSection() -> NSView {
        autoStartSwitch = makeGroupedFormSwitch(target: self, action: #selector(autoStartToggled))
        ephemeralSwitch = makeGroupedFormSwitch(target: self, action: #selector(ephemeralModeToggled))
        ephemeralBaselinePopUp = makeEphemeralBaselinePopUp()
        renderedEphemeralBaselines = nil

        let noSnapshots = GroupedFormStateNote(content: { [weak self] in
            guard let self, instance.snapshotManifest.defaultEphemeralBaseline(preferring: nil) == nil
            else { return nil }
            return EphemeralModeCopy.noSnapshotsCaption(
                capturesBaseline: !instance.hostState.ephemeralModeEnabled
                    && viewModel.capabilities.ephemeralModeEnable(on: instance) == .capturingBaseline)
        })
        ephemeralNoSnapshotsCaption = noSnapshots

        // Reads the resolved baseline rather than the popup's selection, so the
        // caption is never the outgoing VM's while the menu is being rebuilt.
        let baselineCaption = GroupedFormStateNote(content: { [weak self] in
            self?.instance.ephemeralBaselineSnapshot.map {
                EphemeralModeCopy.baselineCaption(for: $0.kind)
            }
        })
        ephemeralBaselineCaption = baselineCaption

        let ephemeralGroup = makeGroupedFormSubOptionGroup(
            primary: GroupedFormNotedRow(
                makeGroupedFormCardRow(
                    "Ephemeral Mode", control: ephemeralSwitch,
                    info: EphemeralModeCopy.popoverParagraphs),
                notes: [noSnapshots]),
            subOption: GroupedFormNotedRow(
                makeGroupedFormCardRow("Baseline snapshot", control: ephemeralBaselinePopUp),
                notes: [baselineCaption]))
        self.ephemeralGroup = ephemeralGroup

        let card = makeGroupedFormCard(
            rows: [
                makeGroupedFormCardRow(
                    "Start when Kernova opens", control: autoStartSwitch, info: Self.autoStartInfo),
                ephemeralGroup,
            ])

        autoStartWarningContainer = NSStackView()
        autoStartWarningContainer.orientation = .vertical
        autoStartWarningContainer.alignment = .leading
        autoStartWarningContainer.spacing = Spacing.small
        autoStartWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        return makeGroupedFormSection([
            lockRegistry.makeHeader("Startup"), card, autoStartWarningContainer,
        ])
    }

    private func makeEphemeralBaselinePopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        popUp.target = self
        popUp.action = #selector(ephemeralBaselineChanged)
        return popUp
    }

    // MARK: - Refresh

    private func refreshGeneral() {
        let canRename = viewModel.capabilities.isAvailable(.rename, on: instance)
        nameLabel.update(text: instance.name, controlsEnabled: canRename)
        applyGroupedFormRowTitleEnabled(canRename, of: nameLabel)
        // A borderless button grays its own title when disabled and a label does
        // not, so the unavailable-rename appearance is applied here. Never over
        // an open box: what is being typed is not disabled.
        if !nameLabel.isEditing {
            nameLabel.textColor = canRename ? .labelColor : .disabledControlTextColor
        }
        refreshInstallRecord()
        refreshMachineID()
        let reportedOSVersion = instance.guestOSVersionDisplay
        guestOSVersionValueLabel?.stringValue = reportedOSVersion ?? ""
        guestOSVersionRow?.isHidden = reportedOSVersion == nil
        // The label's own editing flag is the commit gate, so a rename this
        // surface lost mid-handoff — the marker has already moved to the sidebar
        // — still commits the text typed here.
        if isRenaming {
            nameLabel.beginEditing()
        } else {
            nameLabel.endEditing()
        }
    }

    /// Renders the machine ID's fingerprint and the other VMs holding it.
    private func refreshMachineID() {
        let fingerprint = instance.machineIdentity?.fingerprint
        machineIDRow?.isHidden = fingerprint == nil
        machineIDValueLabel?.stringValue = fingerprint?.short ?? ""
        machineIDValueLabel?.toolTip = fingerprint?.digest
        sharedMachineIDNote?.refresh()
    }

    /// Renders the install record — built or revised while the pane is open,
    /// since setup completing writes it.
    private func refreshInstallRecord() {
        let record = instance.configuration.installedImage
        installedImageValueLabel?.stringValue = record?.displayName ?? ""
        installedImageValueLabel?.toolTip =
            switch record {
            case .linuxCatalogImage(_, _, let digest): digest?.filename
            case .linuxURLImage(let url, _): url.absoluteString
            case .macOSRestoreImage, nil: nil
            }
        installedImageRow?.isHidden = record == nil

        let digest = record?.digest
        digestRow?.isHidden = digest == nil
        verificationRow?.isHidden = digest == nil
        digestCopyButton?.value = digest?.sha256
        guard let digest else { return }
        digestValueLabel?.stringValue = Self.abbreviatedDigest(digest.sha256)
        digestValueLabel?.toolTip = digest.sha256
        verificationValueLabel?.stringValue = digest.verificationSummary
        verificationValueLabel?.toolTip =
            switch digest.matched {
            case .checksumList(let url): url.absoluteString
            case .enteredByUser: nil
            case nil: Self.uncheckedDigestToolTip
            }
    }

    private func refreshStartup() {
        let autoStarts = instance.hostState.startsAutomaticallyOnLaunch
        autoStartSwitch.state = autoStarts ? .on : .off
        applyGroupedFormRowEnabled(
            isAvailable(VMConfigurationKeyRegistry.autoStart, writing: String(!autoStarts)),
            control: autoStartSwitch)
        refreshEphemeralMode()

        let message = resolved.warnings[.general]
        guard message != renderedAutoStartWarning else { return }
        renderedAutoStartWarning = message
        autoStartWarningContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let message else { return }
        let banner = makeGroupedFormBanner(
            symbolName: "exclamationmark.triangle.fill", tint: .systemYellow, message: message)
        addGroupedFormFullWidth(banner, to: autoStartWarningContainer)
    }

    /// Renders the Ephemeral Mode toggle, its baseline menu, the caption naming
    /// what the chosen baseline returns the VM to, and the one that stands in
    /// for a VM with nothing to use as a baseline.
    ///
    /// Both controls stay live while the pane is read-only: the flag is read at
    /// power-off, and a running ephemeral VM is exactly where a user reaches for
    /// the switch.
    private func refreshEphemeralMode() {
        let manifest = instance.snapshotManifest
        let enabled = instance.hostState.ephemeralModeEnabled
        ephemeralSwitch.state = enabled ? .on : .off
        applyGroupedFormRowEnabled(
            VMOverviewToggle.ephemeralMode.isFlippable(
                from: enabled, on: instance, capabilities: viewModel.capabilities),
            control: ephemeralSwitch)
        applyGroupedFormRowEnabled(
            isAvailable(
                VMConfigurationKeyRegistry.ephemeralBaseline,
                writing: instance.hostState.ephemeralBaselineSnapshotID?.uuidString ?? ""),
            control: ephemeralBaselinePopUp)
        ephemeralNoSnapshotsCaption?.refresh()
        ephemeralGroup?.isSubOptionHidden = !enabled

        let listed = manifest.ordered.map { BaselineMenuItem(id: $0.id, title: $0.name) }
        if listed != renderedEphemeralBaselines {
            renderedEphemeralBaselines = listed
            // Items are built and added directly: `addItem(withTitle:)` removes
            // an existing entry carrying the same title, and nothing keeps two
            // snapshots from sharing a name — the entry it drops is a baseline
            // that could then neither be shown as selected nor picked.
            let menu = NSMenu()
            for item in listed {
                let menuItem = NSMenuItem()
                menuItem.title = item.title
                menuItem.representedObject = item.id
                menu.addItem(menuItem)
            }
            ephemeralBaselinePopUp.menu = menu
        }
        ephemeralBaselineCaption?.refresh()
        guard
            let index = ephemeralBaselinePopUp.itemArray.firstIndex(where: {
                ($0.representedObject as? UUID) == instance.hostState.ephemeralBaselineSnapshotID
            })
        else { return }
        ephemeralBaselinePopUp.selectItem(at: index)
    }
    @objc private func startRename() {
        guard viewModel.capabilities.isAvailable(.rename, on: instance) else { return }
        viewModel.renameVMInDetail(instance)
    }

    /// Disables the name field's right-click "Rename" while the VM can't be
    /// renamed (e.g. while running), mirroring the disabled name button.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(startRename) {
            return viewModel.capabilities.isAvailable(.rename, on: instance)
        }
        return true
    }

    @objc private func ephemeralBaselineChanged() {
        guard let id = ephemeralBaselinePopUp.selectedItem?.representedObject as? UUID else {
            #log(Self.logger, .fault, "Ephemeral baseline popup selection carries no snapshot")
            assertionFailure("Ephemeral baseline popup selection carries no snapshot")
            return
        }
        write(VMConfigurationKeyRegistry.ephemeralBaseline.assigning(id.uuidString))
    }

    // MARK: - Mirrored toggles

    // Both hand the intended value to the shell, which owns the one write path
    // this setting's overview card shares.

    @objc private func autoStartToggled() {
        setToggle(.autoStart, to: autoStartSwitch.state == .on)
    }

    @objc private func ephemeralModeToggled() {
        setToggle(.ephemeralMode, to: ephemeralSwitch.state == .on)
    }
}
