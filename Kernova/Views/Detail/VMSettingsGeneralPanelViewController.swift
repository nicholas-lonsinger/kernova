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
        super.init(nibName: nil, bundle: nil)
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
        nameRowIsEditing = false
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

    /// Ends an in-flight name rename for the outgoing instance while it is still
    /// bound: a rebuild resets the session flags without commit/cancel, which
    /// would drop the typed text, strand `activeRename` at the old id
    /// (re-selecting that VM would spontaneously reopen the box), and leave the
    /// outside-click monitor installed.
    func willRebind() {
        if isViewLoaded, nameRowIsEditing {
            endNameRenameSession()
        }
    }

    /// Ends an in-flight rename through the commit path (focus loss commits):
    /// leaving the session flags armed would re-show the edit box on reappear
    /// with no outside-click monitor and a stale marker.
    func prepareForDisappearance() {
        if nameRowIsEditing {
            endNameRenameSession()
        }
        removeNameOutsideClickMonitor()
    }

    /// Fallback teardown of the name-rename monitor for any path that tears the
    /// pane down without the orderly one.
    deinit {
        MainActor.assumeIsolated { removeNameOutsideClickMonitor() }
    }

    // General
    private var nameButton = NSButton()
    private let nameField = NSTextField()
    /// The "Installed From" row and its value label, hidden while the VM
    /// carries no record of the image it was set up from.
    private var installedImageRow: GroupedFormCollapsibleRow?
    private var installedImageValueLabel: NSTextField?
    /// The OS version row and its value label, hidden until an agent reports
    /// one; both `nil` for Linux guests, which have no agent to report one.
    private var guestOSVersionRow: GroupedFormCollapsibleRow?
    private var guestOSVersionValueLabel: NSTextField?
    private var nameDisplayRow = NSView()
    private var nameEditRow = NSView()
    private var nameRowIsEditing = false
    /// Suppresses the end-editing commit while a path that already settled the
    /// rename (Escape's cancel) resigns the field editor.
    private var suppressNameEndEditingCommit = false
    /// Caps the name edit box at its text width so it hugs the name and grows as
    /// you type (right-aligned, the leading spacer absorbs the slack).
    ///
    /// A `<=` bound, not `==`, so a name wider than the form scrolls instead of
    /// stretching the window. Created once for the lifetime of the reused
    /// `nameField`, *not* per `buildForm()`: the constraint lives on the field,
    /// so a copy minted on every instance swap outlives its build cycle — the
    /// caps accumulate and the smallest constant wins.
    private lazy var nameEditMaxWidth: NSLayoutConstraint = {
        let constraint = nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        constraint.priority = .defaultHigh
        return constraint
    }()
    /// Active only while renaming: ends the edit on a click outside the name field.
    ///
    /// Resigns the field editor (committing the current text) — AppKit doesn't end
    /// field editing when a click lands on the settings card's non-focusable
    /// space, so without this the box would linger.
    private var nameOutsideClickMonitor: Any?

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

    private func buildGeneralSection() -> NSView {
        nameButton = NSButton(title: instance.name, target: self, action: #selector(startRename))
        nameButton.isBordered = false
        nameButton.alignment = .right
        nameButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Right-click "Rename" too, matching the storage rows and sidebar (the
        // item is gated by `validateMenuItem` when the VM can't be renamed).
        let renameMenu = NSMenu()
        let renameItem = NSMenuItem(title: "Rename", action: #selector(startRename), keyEquivalent: "")
        renameItem.target = self
        renameMenu.addItem(renameItem)
        nameButton.menu = renameMenu
        nameDisplayRow = makeGroupedFormCardRow("Name", control: nameButton)

        nameField.placeholderString = "Name"
        nameField.alignment = .right
        nameField.delegate = self
        nameField.cell?.isScrollable = true
        // The field fills the row (the leading spacer absorbs the slack) and
        // `nameEditMaxWidth` caps it at the text width. Hug is one step below the
        // spacer's so the field claims the slack first; compression is low so it
        // yields (scrolls) rather than pushes.
        nameField.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameEditRow = makeGroupedFormCardRow("Name", control: nameField)
        // `.fill` (vs the default gravity-areas) actually stretches the field to
        // fill the row, so it claims the slack and the `<=` cap below binds —
        // otherwise the scrollable field sits at its sliver-sized intrinsic.
        (nameEditRow as? NSStackView)?.distribution = .fill
        nameEditRow.isHidden = true

        nameEditMaxWidth.isActive = true

        let nameRow = NSStackView(views: [nameDisplayRow, nameEditRow])
        nameRow.orientation = .vertical
        nameRow.alignment = .leading
        nameRow.spacing = Spacing.none
        nameDisplayRow.widthAnchor.constraint(equalTo: nameRow.widthAnchor).isActive = true
        nameEditRow.widthAnchor.constraint(equalTo: nameRow.widthAnchor).isActive = true

        var rows: [NSView] = [
            nameRow,
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
        nameButton.title = instance.name
        nameButton.isEnabled = viewModel.capabilities.isAvailable(.rename, on: instance)
        let installedImage = instance.configuration.installedImage?.displayName
        installedImageValueLabel?.stringValue = installedImage ?? ""
        installedImageRow?.isHidden = installedImage == nil
        let reportedOSVersion = instance.guestOSVersionDisplay
        guestOSVersionValueLabel?.stringValue = reportedOSVersion ?? ""
        guestOSVersionRow?.isHidden = reportedOSVersion == nil
        let renaming = isRenaming
        if renaming != nameRowIsEditing {
            if renaming {
                nameRowIsEditing = true
                nameDisplayRow.isHidden = true
                nameEditRow.isHidden = false
                nameField.stringValue = instance.name
                view.window?.makeFirstResponder(nameField)
                // Re-seed after taking focus: the makeFirstResponder above can
                // synchronously commit the *other* surface's pending rename,
                // changing `instance.name` after the seed — and the mutation
                // lands inside this very apply() pass, so no later pass repairs
                // an already-open box.
                nameField.stringValue = instance.name
                if let editor = nameField.currentEditor() {
                    editor.string = instance.name
                    editor.selectAll(nil)
                }
                nameEditMaxWidth.constant = InlineRenameSizing.boxWidth(
                    for: instance.name, font: Typography.body)
                installNameOutsideClickMonitor()
            } else {
                removeNameOutsideClickMonitor()
                // End a still-active editor session BEFORE flipping the session
                // flag or hiding the row: the resign flows through
                // `controlTextDidEndEditing`, whose commit gate reads
                // `nameRowIsEditing`, so a superseded rename's in-flight text
                // still commits and no focused-but-invisible editor survives to
                // swallow keystrokes.
                if nameField.currentEditor() != nil {
                    Self.logger.debug(
                        "Ending superseded name rename session via end-editing commit")
                    view.window?.makeFirstResponder(nil)
                }
                nameRowIsEditing = false
                nameDisplayRow.isHidden = false
                nameEditRow.isHidden = true
            }
        }
    }

    /// Installs a local mouse-down monitor that ends the rename on an outside click.
    ///
    /// Resigns the field editor so `controlTextDidEndEditing` commits when the
    /// user clicks anywhere outside the name field — AppKit doesn't end field
    /// editing on clicks that land on non-focusable space in the settings card.
    private func installNameOutsideClickMonitor() {
        removeNameOutsideClickMonitor()
        nameOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isRenaming else { return event }
            let pointInField = self.nameField.convert(event.locationInWindow, from: nil)
            if !self.nameField.bounds.contains(pointInField) {
                self.view.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeNameOutsideClickMonitor() {
        if let monitor = nameOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            nameOutsideClickMonitor = nil
        }
    }

    /// Ends an in-flight name rename through the end-editing commit path.
    ///
    /// For paths that bypass `refreshGeneral`'s teardown transition (instance
    /// rebind, view disappearance): those reset `nameRowIsEditing` out-of-band,
    /// stranding the typed text, the marker, and the outside-click monitor.
    private func endNameRenameSession() {
        if nameField.currentEditor() != nil {
            view.window?.makeFirstResponder(nil)
        }
        removeNameOutsideClickMonitor()
        nameRowIsEditing = false
        nameDisplayRow.isHidden = false
        nameEditRow.isHidden = true
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

// MARK: - NSTextFieldDelegate

extension VMSettingsGeneralPanelViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameField else { return }
        let live = nameField.currentEditor()?.string ?? nameField.stringValue
        nameEditMaxWidth.constant = InlineRenameSizing.boxWidth(for: live, font: Typography.body)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case nameField:
            // Gate on the local session flag, not the model marker: when this
            // surface's rename is superseded mid-handoff the marker has already
            // moved to the other surface, but the in-flight text must still
            // commit.
            if nameRowIsEditing, !suppressNameEndEditingCommit {
                viewModel.commitRename(
                    for: instance, newName: nameField.stringValue, from: .detail)
            }
        default:
            break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === nameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Resign instead of committing directly: the end-editing path is the
            // single commit path, so Return, outside clicks, and superseded
            // teardowns all commit the same way.
            view.window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Clear the rename first, then end the field editor with the
            // commit suppressed so the resign can't write the live buffer.
            viewModel.cancelRename(for: instance, from: .detail)
            suppressNameEndEditingCommit = true
            view.window?.makeFirstResponder(nil)
            suppressNameEndEditingCommit = false
            return true
        }
        return false
    }
}
