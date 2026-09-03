import AppKit
import os

/// The General category: the VM's identity rows and its startup behavior.
@MainActor
final class VMSettingsGeneralPanelViewController: NSViewController, VMSettingsPanel,
    NSMenuItemValidation
{
    private static let logger = Logger(
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
    /// The "Installed From" row and its value label, hidden while the VM
    /// carries no record of the image it was set up from.
    private var installedImageRow: GroupedFormCollapsibleRow?
    private var installedImageValueLabel: NSTextField?
    /// The OS version row and its value label, hidden until an agent reports
    /// one; both `nil` for Linux guests, which have no agent to report one.
    private var guestOSVersionRow: GroupedFormCollapsibleRow?
    private var guestOSVersionValueLabel: NSTextField?

    // Startup
    private var autoStartSwitch = NSSwitch()
    /// Holds the banner naming how many macOS guests are marked to start at
    /// launch, when that exceeds what macOS runs at once.
    private var autoStartWarningContainer = NSStackView()
    private var ephemeralSwitch = NSSwitch()
    /// The Ephemeral Mode row's title label, retained so `refreshStartup` can
    /// gray it in step with a switch a VM without snapshots can't use.
    private var ephemeralLabel = NSTextField()
    private var ephemeralBaselinePopUp = NSPopUpButton()
    /// The Ephemeral Mode row and its Baseline snapshot sub-option, retained so
    /// the sub-option shows only while the mode is on.
    private var ephemeralGroup: GroupedFormSubOptionGroup?
    /// Explains that a baseline needs a snapshot first; hidden once the VM has one.
    private var ephemeralNoSnapshotsCaption = NSView()
    /// One entry of the Baseline snapshot menu, as rendered.
    private struct BaselineMenuItem: Equatable {
        let id: UUID
        let name: String
    }
    /// What the baseline menu was last built from, so it rebuilds exactly when
    /// the list or a listed name changed rather than on every `apply()` pass.
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
        ]
        // Both OS rows are built whatever the VM knows today, then hidden until
        // it knows: an install completing or a first agent Hello fills one in
        // while this pane is on screen, and only `apply()` runs then.
        let installedImage = instance.configuration.installedImage?.displayName
        let installedLabel = makeGroupedFormValueLabel(installedImage ?? "")
        installedImageValueLabel = installedLabel
        let installedRow = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow(
                Self.installedImageRowLabel(guestOS: instance.configuration.guestOS),
                control: installedLabel))
        installedRow.isHidden = installedImage == nil
        installedImageRow = installedRow
        rows.append(installedRow)

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
        return makeGroupedFormSection([lockRegistry.makeHeader("General"), makeGroupedFormCard(rows: rows)])
    }

    // MARK: Startup

    /// Caption under the Startup card: the launch pass walks the library in
    /// sidebar order, so that is the order the marked VMs come up in.
    static let autoStartOrderCaption =
        "Virtual machines start in the order they appear in the sidebar."

    /// The Startup card's two toggles, their captions, and the capacity banner's
    /// container.
    ///
    /// Not `lockable`, and neither switch is in `persistentLockableControls`:
    /// the auto-start flag is read once at app launch, the ephemeral one at
    /// power-off, and neither reaches a `VZVirtualMachineConfiguration` — so
    /// both edit while the VM runs.
    private func buildStartupSection() -> NSView {
        autoStartSwitch = makeGroupedFormSwitch(target: self, action: #selector(autoStartToggled))
        ephemeralSwitch = makeGroupedFormSwitch(target: self, action: #selector(ephemeralModeToggled))
        ephemeralBaselinePopUp = makeEphemeralBaselinePopUp()
        renderedEphemeralBaselines = nil
        let ephemeralGroup = makeGroupedFormSubOptionGroup(
            primary: makeGroupedFormToggleRowWithInfo(
                "Ephemeral Mode", control: ephemeralSwitch,
                paragraphs: EphemeralModeCopy.popoverParagraphs,
                titleLabel: { [weak self] in self?.ephemeralLabel = $0 }),
            subOption: makeGroupedFormCardRow(
                "Baseline snapshot", control: ephemeralBaselinePopUp))
        self.ephemeralGroup = ephemeralGroup

        let card = makeGroupedFormCard(rows: [
            makeGroupedFormToggleRowWithInfo(
                "Start when Kernova opens", control: autoStartSwitch,
                paragraphs: [
                    .body(
                        "Starts this virtual machine each time Kernova opens. A suspended VM resumes from its saved state; one that has not finished its initial setup is left alone."
                    ),
                    .body(
                        "Turn on Open at Login in Settings → General to have it running after you log in."
                    ),
                ]),
            ephemeralGroup,
        ])

        autoStartWarningContainer = NSStackView()
        autoStartWarningContainer.orientation = .vertical
        autoStartWarningContainer.alignment = .leading
        autoStartWarningContainer.spacing = Spacing.small
        autoStartWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        let noSnapshots = makeGroupedFormCaption(EphemeralModeCopy.noSnapshotsCaption)
        noSnapshots.isHidden = true
        ephemeralNoSnapshotsCaption = noSnapshots

        return makeGroupedFormSection([
            lockRegistry.makeHeader("Startup"), card,
            makeGroupedFormCaption(Self.autoStartOrderCaption),
            makeGroupedFormCaption(EphemeralModeCopy.settingsCaption),
            noSnapshots,
            autoStartWarningContainer,
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
        // A borderless button grays its own title when disabled and a label does
        // not, so the unavailable-rename appearance is applied here. Never over
        // an open box: what is being typed is not disabled.
        if !nameLabel.isEditing {
            nameLabel.textColor = canRename ? .labelColor : .disabledControlTextColor
        }
        let installedImage = instance.configuration.installedImage?.displayName
        installedImageValueLabel?.stringValue = installedImage ?? ""
        installedImageRow?.isHidden = installedImage == nil
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

    private func refreshStartup() {
        autoStartSwitch.state = instance.configuration.startsAutomaticallyOnLaunch ? .on : .off
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

    /// Renders the Ephemeral Mode toggle, its baseline menu, and the captions
    /// that stand in for a VM with nothing to use as a baseline.
    ///
    /// Both controls stay live while the pane is read-only: the flag is read at
    /// power-off, and a running ephemeral VM is exactly where a user reaches for
    /// the switch.
    private func refreshEphemeralMode() {
        let manifest = instance.snapshotManifest
        let enabled = instance.configuration.ephemeralModeEnabled
        ephemeralSwitch.state = enabled ? .on : .off
        // A VM with nothing to fall back to can't take the mode — but one that
        // is already in it can always be taken back out.
        let offerable = !manifest.isEmpty || enabled
        applyGroupedFormRowEnabled(offerable, control: ephemeralSwitch, label: ephemeralLabel)
        ephemeralNoSnapshotsCaption.isHidden = !manifest.isEmpty
        ephemeralGroup?.isSubOptionHidden = !enabled

        let listed = manifest.ordered.map { BaselineMenuItem(id: $0.id, name: $0.name) }
        if listed != renderedEphemeralBaselines {
            renderedEphemeralBaselines = listed
            ephemeralBaselinePopUp.menu?.removeAllItems()
            for item in listed {
                ephemeralBaselinePopUp.addItem(withTitle: item.name)
                ephemeralBaselinePopUp.lastItem?.representedObject = item.id
            }
        }
        guard
            let index = ephemeralBaselinePopUp.itemArray.firstIndex(where: {
                ($0.representedObject as? UUID) == instance.configuration.ephemeralBaselineSnapshotID
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
            Self.logger.fault("Ephemeral baseline popup selection carries no snapshot")
            assertionFailure("Ephemeral baseline popup selection carries no snapshot")
            return
        }
        writeConfig { $0.applyEphemeralMode(enabled: true, baseline: id) }
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
