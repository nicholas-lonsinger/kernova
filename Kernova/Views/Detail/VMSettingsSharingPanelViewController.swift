import AppKit

/// The Sharing category: shared directories, the guest-agent group (macOS) or
/// the standalone clipboard section (Linux) beside them, and the USB
/// accessories this VM takes back on its own.
@MainActor
final class VMSettingsSharingPanelViewController: NSViewController, VMSettingsPanel {
    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.sharing
    private var lockRegistry = VMSettingsLockRegistry()

    private let panelStack = NSStackView()

    private var currentSharedDirectories: [SharedDirectory] {
        instance.configuration.sharedDirectories ?? []
    }

    init(context: VMSettingsPanelContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsSharingPanelViewController does not support NSCoder")
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

        var sections = [
            buildSharedDirectoriesSection(),
            // macOS: clipboard rides the agent's vsock channel, so it nests in
            // the agent group rather than forming a sibling section. Linux:
            // clipboard is SPICE-based, so it stands alone.
            isGuestAgentSectionVisible(guestOS: instance.configuration.guestOS)
                ? buildGuestAgentSection() : buildClipboardSection(),
        ]
        // Absent, not disabled, in a build that cannot pass accessories
        // through: there is nothing it could ever list.
        pairingSection = nil
        if viewModel.supportsUSBAccessories {
            let section = buildUSBPairingsSection()
            pairingSection = section
            sections.append(section)
        }
        for section in sections {
            panelStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
        }
        // The monitored paths are this instance's, so a rebuild re-seeds them.
        context.seedFileMonitor()
        armFileMonitorLoop()
        armPairingLoop()
    }

    /// ``prepareForDisappearance()`` cancels the observation loop, so
    /// re-appearing starts a fresh one — otherwise a change while hidden freezes
    /// the missing-folder badges for good.
    func hostDidAppear() {
        armFileMonitorLoop()
        armPairingLoop()
    }

    func refresh() {
        lockRegistry.apply(isReadOnly: !canEditSharedDirectories)
        refreshGuestAgent()
        refreshClipboard()
        refreshSharedList()
        refreshUSBPairings()
        context.seedFileMonitor()
    }

    func prepareForDisappearance() {
        fileMonitorLoop?.cancel()
        fileMonitorLoop = nil
        pairingLoop?.cancel()
        pairingLoop = nil
    }

    /// Re-renders the shared list whenever a watched path appears or
    /// disappears, so a folder that goes missing badges without a revisit.
    private func armFileMonitorLoop() {
        fileMonitorLoop?.cancel()
        fileMonitorLoop = observeRecurring(
            track: { [monitor = context.fileMonitor] in _ = monitor.existsByPath },
            apply: { [weak self] in self?.refreshSharedList() })
    }

    /// Whether this VM's shared-directory list takes an edit right now.
    private var canEditSharedDirectories: Bool {
        viewModel.capabilities.isAvailable(.editSharedDirectories, on: instance)
    }

    // Shared Directories
    private var sharedListStack = NSStackView()
    /// The shared-directory rows and the diff behind them, rebuilt with the
    /// section's list stack.
    private var sharedList: VMSettingsKeyedListController<VMSettingsRenderedRow, AttachmentRowView>?
    private var fileMonitorLoop: ObservationLoop?

    // Guest Agent
    private var logForwardingSwitch = NSSwitch()
    private var installReminderSwitch = NSSwitch()
    /// The install-reminder row's title label, retained so `refreshGuestAgent`
    /// can gray it in step with the switch.
    private var installReminderLabel = NSTextField()
    /// Explains the disabled install-reminder row while the prompt is off
    /// app-wide; hidden otherwise.
    private var installReminderOverrideCaption = NSView()

    // Drag and drop (macOS guests only)
    private var dropFilesSwitch = NSSwitch()

    // Remembered USB accessories
    private var pairingListStack = NSStackView()
    /// The whole section, hidden while this VM remembers nothing; `nil` in a
    /// build that never built one.
    private var pairingSection: NSView?
    private var pairingLoop: ObservationLoop?

    // Clipboard
    private var clipboardSwitch = NSSwitch()
    private var clipboardPassthroughSwitch = NSSwitch()
    /// The passthrough row's title label, retained so `refreshClipboard` can gray
    /// it in step with the switch.
    private var clipboardPassthroughLabel = NSTextField()
    private var clipboardCaption = NSView()

    // MARK: Shared Directories

    private func buildSharedDirectoriesSection() -> NSView {
        sharedListStack = makeGroupedFormListStack()
        sharedList = VMSettingsKeyedListController(
            listStack: sharedListStack, emptyMessage: "No shared directories")
        let add = makeGroupedFormPushButton("Add Shared Directory…", target: self, action: #selector(addSharedTapped))
        let card = makeGroupedFormCard(rows: [
            sharedListStack, lockRegistry.lockable(makeGroupedFormButtonRow([add]), add),
        ])

        let paragraphs: [InfoPopoverParagraph] =
            instance.configuration.guestOS == .linux
            ? [
                .body(
                    "Exposed as virtiofs mounts. Each share gets a numbered tag (`share0`, `share1`, …) in list order. Mount with:"
                ),
                .code("mount -t virtiofs share0 /mnt/myshare"),
                .body(
                    "VirtioFS has known framework limitations — files may intermittently appear missing, and host/guest permission mapping can differ."
                ),
            ]
            : [
                .body("Auto-mounts at `/Volumes/My Shared Files/` in the guest."),
                .body(
                    "VirtioFS has known framework limitations — files may intermittently appear missing, and host/guest permission mapping can differ."
                ),
            ]
        return makeGroupedFormSection([
            lockRegistry.makeHeader("Shared Directories", lockable: true, paragraphs: paragraphs), card,
        ])
    }

    // MARK: Remembered USB Accessories

    /// The accessories this VM takes back on its own, each with the button that
    /// forgets it.
    ///
    /// Here rather than in the Virtual Machine menu because the rows that most
    /// need removing name hardware that is in a drawer, and a menu can only
    /// list what is plugged in. Here rather than Storage because a passthrough
    /// accessory is not part of the VM's configuration, while Sharing is
    /// already what the host hands this guest while it runs.
    private func buildUSBPairingsSection() -> NSView {
        pairingListStack = makeGroupedFormListStack()
        // Not lockable: a remembered accessory is a preference about what to
        // attach, so it takes an edit whatever the VM is doing.
        return makeGroupedFormSection([
            lockRegistry.makeHeader(
                "Remembered USB Accessories",
                paragraphs: [
                    .body(
                        "Passing a USB accessory through to this virtual machine remembers it. Kernova hands it back whenever both the accessory and this virtual machine are available — when you plug it in, and when the virtual machine starts."
                    ),
                    .body(
                        "Taking an accessory back from the USB Device menu forgets it, as does removing it here."
                    ),
                ]),
            makeGroupedFormCard(rows: [pairingListStack]),
        ])
    }

    private func refreshUSBPairings() {
        guard let pairingSection else { return }
        let pairings = instance.usbPairings.pairings
        // Absent rather than an empty list: a VM that has never been handed an
        // accessory has nothing to say about them.
        pairingSection.isHidden = instance.usbPairings.isEmpty
        clearGroupedFormStack(pairingListStack)
        for pairing in pairings {
            let row = USBAccessoryPairingRowView(
                pairing: pairing, target: self, action: #selector(forgetPairingTapped))
            pairingListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: pairingListStack.widthAnchor).isActive = true
        }
    }

    /// Re-renders the list whenever the set changes, so an accessory placed or
    /// taken back while this panel is open lands without a revisit.
    private func armPairingLoop() {
        pairingLoop?.cancel()
        guard pairingSection != nil else { return }
        pairingLoop = observeRecurring(
            track: { [instance] in _ = instance.usbPairings },
            apply: { [weak self] in self?.refreshUSBPairings() })
    }

    @objc private func forgetPairingTapped(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        viewModel.forgetUSBAccessory(key: key, on: instance)
    }

    // MARK: Guest Agent

    /// Caption shown beneath the macOS Guest Agent card.
    static let agentDependencyCaption =
        "Clipboard sharing, drag and drop, and log forwarding require the Kernova guest agent. Kernova offers to install or update it from the clipboard window."

    /// Shown under the Guest Agent card while the app-wide preference turns the
    /// install prompt off, so the greyed row reads as controlled elsewhere.
    static let installPromptDisabledCaption =
        "The install reminder is turned off for all virtual machines in Settings → Reminders."

    /// Info-popover copy for the "Automatic clipboard passthrough" toggle, shared
    /// by the macOS and Linux clipboard sections.
    static let passthroughInfoParagraphs: [InfoPopoverParagraph] = [
        .body(
            "Forwards this Mac's clipboard to the guest automatically and writes the guest's clipboard here — no clipboard window step in either direction. Requires clipboard sharing and can be toggled while the VM runs."
        ),
        .body(
            "Because the guest then continuously reads whatever you copy (including passwords), turning it on asks for confirmation."
        ),
    ]

    /// Guest Agent group for **macOS** guests, holding the agent-management
    /// toggles plus Clipboard sharing, which rides the agent's vsock channel.
    private func buildGuestAgentSection() -> NSView {
        logForwardingSwitch = makeGroupedFormSwitch(target: self, action: #selector(logForwardingToggled))
        installReminderSwitch = makeGroupedFormSwitch(target: self, action: #selector(installReminderToggled))
        clipboardSwitch = makeGroupedFormSwitch(target: self, action: #selector(clipboardToggled))
        clipboardPassthroughSwitch = makeGroupedFormSwitch(target: self, action: #selector(clipboardPassthroughToggled))
        dropFilesSwitch = makeGroupedFormSwitch(target: self, action: #selector(dropFilesToggled))
        // Not lockable — every toggle here takes effect live.
        let card = makeGroupedFormCard(rows: [
            makeGroupedFormRowWithInfo(
                "Forward guest logs", control: logForwardingSwitch,
                paragraphs: [
                    .body(
                        "Streams `os.Logger` records from the macOS guest agent to the host so they appear in Console.app under `app.kernova.guest`. Off by default; can be toggled while the VM is running."
                    )
                ]),
            // Passthrough rides on sharing — it goes inert when sharing is off —
            // so it nests as a sub-option rather than an equal sibling toggle.
            makeGroupedFormSubOptionGroup(
                primary: makeGroupedFormRowWithInfo(
                    "Clipboard sharing", control: clipboardSwitch,
                    paragraphs: [
                        .body("Exchanges clipboard text between host and guest.")
                    ]),
                subOption: makeGroupedFormRowWithInfo(
                    "Automatic clipboard passthrough", control: clipboardPassthroughSwitch,
                    paragraphs: Self.passthroughInfoParagraphs,
                    titleLabel: { [weak self] in self?.clipboardPassthroughLabel = $0 })),
            makeGroupedFormRowWithInfo(
                "Drag and drop files", control: dropFilesSwitch,
                paragraphs: [
                    .body(
                        "Lets you drag files and folders from this Mac onto the VM display; the guest agent saves them to the guest's Downloads folder. Independent of clipboard sharing, and can be toggled while the VM is running."
                    )
                ]),
            makeGroupedFormRowWithInfo(
                "Show install reminder", control: installReminderSwitch,
                paragraphs: [
                    .body(
                        "Surfaces the install icon in the sidebar when the guest agent has not yet connected. Turn off to suppress the nudge for this VM. The more urgent indicators (update available, didn't reconnect, unresponsive) are not affected."
                    )
                ],
                titleLabel: { [weak self] in self?.installReminderLabel = $0 }),
        ])
        let overrideCaption = makeGroupedFormCaption(Self.installPromptDisabledCaption)
        overrideCaption.isHidden = true
        installReminderOverrideCaption = overrideCaption
        return makeGroupedFormSection([
            lockRegistry.makeHeader("Guest Agent"), card, makeGroupedFormCaption(Self.agentDependencyCaption),
            overrideCaption,
        ])
    }

    // MARK: Clipboard

    /// Standalone Clipboard section for **Linux** guests, whose clipboard rides
    /// SPICE (`spice-vdagent`) and is independent of the Kernova guest agent.
    private func buildClipboardSection() -> NSView {
        clipboardSwitch = makeGroupedFormSwitch(target: self, action: #selector(clipboardToggled))
        clipboardPassthroughSwitch = makeGroupedFormSwitch(target: self, action: #selector(clipboardPassthroughToggled))
        let caption = makeGroupedFormCaption(
            "Takes effect on next start — Linux guests configure SPICE at VM start time.")
        caption.textColor = .systemOrange
        caption.isHidden = true
        clipboardCaption = caption

        let body: InfoPopoverParagraph = .body(
            "Exchanges clipboard text between host and guest. Requires `spice-vdagent` installed in the guest via its package manager."
        )
        // Passthrough is host-side (it polls/writes the host pasteboard), so unlike
        // sharing it takes effect live for Linux guests too.
        return makeGroupedFormSection([
            lockRegistry.makeHeader("Clipboard", paragraphs: [body]),
            makeGroupedFormCard(rows: [
                makeGroupedFormSubOptionGroup(
                    primary: makeGroupedFormCardRow("Clipboard sharing", control: clipboardSwitch),
                    subOption: makeGroupedFormRowWithInfo(
                        "Automatic clipboard passthrough", control: clipboardPassthroughSwitch,
                        paragraphs: Self.passthroughInfoParagraphs,
                        titleLabel: { [weak self] in self?.clipboardPassthroughLabel = $0 }))
            ]),
            clipboardCaption,
        ])
    }

    private func refreshGuestAgent() {
        guard isGuestAgentSectionVisible(guestOS: instance.configuration.guestOS) else { return }
        logForwardingSwitch.state = instance.configuration.agentLogForwardingEnabled ? .on : .off
        dropFilesSwitch.state = instance.configuration.dropFilesEnabled ? .on : .off
        // The per-VM flag keeps its value while the app-wide preference overrides
        // it, so the switch still shows what this VM reverts to when the
        // preference is turned back on — it just can't be changed from here.
        installReminderSwitch.state = instance.configuration.agentInstallNudgeDismissed ? .off : .on
        let overridden = viewModel.agentInstallPromptDisabled
        applyGroupedFormRowEnabled(
            !overridden, control: installReminderSwitch, label: installReminderLabel)
        installReminderOverrideCaption.isHidden = !overridden
    }

    private func refreshClipboard() {
        clipboardSwitch.state = instance.configuration.clipboardSharingEnabled ? .on : .off
        // Passthrough is hot-toggleable, so it isn't in
        // `persistentLockableControls`; its enablement is gated here instead.
        clipboardPassthroughSwitch.state = instance.configuration.clipboardPassthroughEnabled ? .on : .off
        applyGroupedFormRowEnabled(
            instance.configuration.clipboardSharingEnabled,
            control: clipboardPassthroughSwitch, label: clipboardPassthroughLabel)
        // The "takes effect on next start" caption is built only by the Linux
        // standalone section, so gate it here.
        guard instance.configuration.guestOS == .linux else { return }
        clipboardCaption.isHidden = !isReadOnly
    }

    private func refreshSharedList() {
        let controlsEnabled = canEditSharedDirectories
        let models = currentSharedDirectories.map { directory -> VMSettingsRenderedRow in
            let isMissing = !context.fileMonitor.exists(directory.path)
            return VMSettingsRenderedRow(
                id: directory.id,
                iconSystemName: "folder",
                title: directory.displayName,
                notes: "",
                subtitle: directory.path,
                isMissing: isMissing,
                missingPath: isMissing ? directory.path : nil,
                readOnly: directory.readOnly,
                controlsEnabled: controlsEnabled)
        }
        sharedList?.update(
            models,
            makeRow: { model in makeSharedRow(model) },
            applyRow: { model, row in
                row.update(
                    title: model.title, notes: model.notes, iconSystemName: model.iconSystemName,
                    missingPath: model.missingPath, readOnly: model.readOnly,
                    controlsEnabled: model.controlsEnabled)
                // The attachment lists repaint their subtitle from an off-main
                // size read, so the row leaves that field alone; a share's
                // subtitle is its path and is written here.
                applyAttachmentSubtitle(
                    to: row.subtitleField, path: model.subtitle, isMissing: model.isMissing)
            })
    }

    /// Builds one shared-directory row.
    ///
    /// The name is the folder's — which is also what the guest mounts by — and
    /// a share carries no note, so the title line renders without its inline
    /// editor while the read-only switch and the remove button stay live.
    private func makeSharedRow(_ model: VMSettingsRenderedRow) -> AttachmentRowView {
        let icon = AttachmentIconButton()
        icon.configure(systemName: model.iconSystemName, missingPath: model.missingPath)
        let row = AttachmentRowView(
            itemID: model.id,
            title: model.title,
            notes: model.notes,
            controlsEnabled: model.controlsEnabled,
            icon: icon,
            subtitle: makeAttachmentSubtitleLabel(path: model.subtitle, isMissing: model.isMissing),
            readOnlyToggle: makeGroupedFormReadOnlySwitch(
                id: model.id, isOn: model.readOnly, enabled: model.controlsEnabled, target: self,
                action: #selector(sharedReadOnlyToggled)),
            readOnlyCaption: makeGroupedFormReadOnlyCaption(),
            ejectButton: makeGroupedFormEjectButton(
                id: model.id, enabled: model.controlsEnabled, target: self,
                action: #selector(sharedDeleteTapped)),
            isTitleEditable: false)
        row.contextMenu = { [weak self] in self?.buildSharedContextMenu(model.id) }
        return row
    }

    /// Builds the right-click menu for a shared-directory row, lazily at click
    /// time so it reflects whether the folder is there now.
    private func buildSharedContextMenu(_ id: UUID) -> NSMenu? {
        guard let directory = currentSharedDirectories.first(where: { $0.id == id }) else {
            return nil
        }
        let menu = NSMenu()
        // Show in Finder's enablement is managed here, from file presence, so
        // opt out of auto-validation.
        menu.autoenablesItems = false
        let showInFinder = sharedMenuItem(
            "Show in Finder", #selector(menuSharedShowInFinder(_:)), id)
        // Nothing to reveal when the folder is gone.
        showInFinder.isEnabled = context.fileMonitor.exists(directory.path)
        menu.addItem(showInFinder)
        menu.addItem(sharedMenuItem("Copy Path", #selector(menuSharedCopyPath(_:)), id))
        menu.addItem(sharedMenuItem("Copy File Name", #selector(menuSharedCopyFileName(_:)), id))
        return menu
    }

    private func sharedMenuItem(_ title: String, _ action: Selector, _ id: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id.uuidString
        return item
    }

    /// The folder a shared-directory menu item stands for, read fresh so an
    /// edit landing since the menu was built is reflected.
    private func sharedDirectoryURL(from sender: NSMenuItem) -> URL? {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw),
            let directory = currentSharedDirectories.first(where: { $0.id == id })
        else { return nil }
        return URL(fileURLWithPath: directory.path)
    }

    @objc private func menuSharedShowInFinder(_ sender: NSMenuItem) {
        guard let url = sharedDirectoryURL(from: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func menuSharedCopyPath(_ sender: NSMenuItem) {
        guard let url = sharedDirectoryURL(from: sender) else { return }
        copyToPasteboard(url.path(percentEncoded: false))
    }

    @objc private func menuSharedCopyFileName(_ sender: NSMenuItem) {
        guard let url = sharedDirectoryURL(from: sender) else { return }
        copyToPasteboard(url.lastPathComponent)
    }

    @objc private func logForwardingToggled() {
        writeConfig { $0.agentLogForwardingEnabled = logForwardingSwitch.state == .on }
    }

    @objc private func installReminderToggled() {
        // Routed through the view model's named accessor rather than the generic
        // `writeConfig` so every write of this flag shares one logged path.
        viewModel.setAgentInstallNudgeDismissed(installReminderSwitch.state != .on, for: instance)
    }

    // MARK: Shared

    @objc private func addSharedTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select directories to share with the VM"
        panel.prompt = "Share"
        guard panel.runModal() == .OK else { return }
        viewModel.addSharedDirectories(panel.urls.map(PickedFile.init(picking:)), to: instance)
    }

    @objc private func sharedReadOnlyToggled(_ sender: NSSwitch) {
        guard let id = attachmentUUID(from: sender) else { return }
        viewModel.setSharedDirectoryReadOnly(id, readOnly: sender.state == .on, on: instance)
    }

    @objc private func sharedDeleteTapped(_ sender: NSButton) {
        guard let id = attachmentUUID(from: sender) else { return }
        viewModel.removeSharedDirectory(id, from: instance)
    }

    // MARK: - Mirrored toggles

    // Each hands the intended value to the shell, which owns the one write path
    // every surface showing the setting shares.

    @objc private func clipboardToggled() {
        setToggle(.clipboardSharing, to: clipboardSwitch.state == .on)
    }

    @objc private func dropFilesToggled() {
        setToggle(.dropFiles, to: dropFilesSwitch.state == .on)
    }

    @objc private func clipboardPassthroughToggled() {
        setToggle(.clipboardPassthrough, to: clipboardPassthroughSwitch.state == .on)
    }
}
