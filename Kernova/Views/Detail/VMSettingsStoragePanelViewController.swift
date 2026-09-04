import AppKit
import UniformTypeIdentifiers

/// The Storage category: the VM's disks and its hot-pluggable removable media.
///
/// Both lists are served by one set of row, menu and popover builders
/// parameterized by `AttachmentKind` and dispatching on an
/// `AttachmentRef(kind:id:)`, never a second implementation per list.
@MainActor
final class VMSettingsStoragePanelViewController: NSViewController, VMSettingsPanel {
    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.storage
    /// The Storage Disks section's locked rows — what only a VM whose hardware
    /// is not pinned can change.
    private var lockRegistry = VMSettingsLockRegistry()
    /// The Removable Media section's own, driven by the hot-plug capability
    /// rather than the storage one.
    private var removableLockRegistry = VMSettingsLockRegistry()

    private let panelStack = NSStackView()

    init(context: VMSettingsPanelContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsStoragePanelViewController does not support NSCoder")
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
        removableLockRegistry.removeAll()

        // Each section builds a fresh list stack and a fresh list controller
        // over it, which is what drops the rows and edit state of the VM the
        // panel was showing.
        for section in [buildStorageSection(), buildRemovableMediaSection()] {
            panelStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
        }
        // The monitored paths are this instance's, so a rebuild re-seeds them.
        context.seedFileMonitor()
        armFileMonitorLoop()
    }

    /// ``prepareForDisappearance()`` cancels the observation loop, so
    /// re-appearing starts a fresh one — otherwise a change while hidden freezes
    /// the missing-file badges for good.
    func hostDidAppear() {
        armFileMonitorLoop()
    }

    func refresh() {
        lockRegistry.apply(isReadOnly: !canEditStorageDisks)
        removableLockRegistry.apply(isReadOnly: !canEditRemovableMedia)
        updateStorageLockHintText()
        refreshStorageList()
        refreshRemovableList()
        context.seedFileMonitor()
    }

    func prepareForDisappearance() {
        if reorderSheetPresenter.isShown { reorderSheetPresenter.close() }
        if attachmentInfoPresenter.isShown { attachmentInfoPresenter.close() }
        fileMonitorLoop?.cancel()
        fileMonitorLoop = nil
        // Drop any in-flight inline edit so the flag can't pin a list in a
        // suppressed (never-rebuilds) state across an appear/disappear cycle.
        storageList?.activeEdit = nil
        removableList?.activeEdit = nil
    }

    /// Whether this VM's disk list takes an edit right now.
    ///
    /// The model gate, not the route's `isReadOnly`: a second surface asking
    /// the same question has to get the same answer, and the verb behind every
    /// control here refuses on exactly this.
    private var canEditStorageDisks: Bool {
        viewModel.capabilities.isAvailable(.editStorageDisks, on: instance)
    }

    /// What the Storage Disks header says while its rows are locked by a clone
    /// of this VM still copying its files out of the bundle — the shared
    /// "Editable when stopped" is false in that case for a VM that is stopped.
    static let cloneLockHintText = "Editable when the clone finishes"

    /// The Storage Disks section's lock-hint label, captured via the
    /// registry's `lockHintSink` so its text can follow the clone-in-flight
    /// state rather than only its visibility.
    private var storageLockHintLabel: NSTextField?
    private var storageLockHintView: NSView?

    /// Swaps the Storage Disks lock hint's wording between the shared
    /// "Editable when stopped" and the clone-specific text.
    private func updateStorageLockHintText() {
        let text =
            viewModel.hasCloneInFlight(from: instance)
            ? Self.cloneLockHintText : groupedFormLockHintText
        storageLockHintLabel?.stringValue = text
        storageLockHintView?.toolTip = text
    }

    /// What the Removable Media header says while its rows are locked.
    ///
    /// Its own wording rather than the shared "Editable when stopped": a
    /// running guest takes a hot-plug, so the shared claim is one the user can
    /// disprove in a second. What is left out is a VM mid-save, mid-capture,
    /// mid-restore, or paused to disk — each pins the device set its saved
    /// state or its capture will be read back into.
    static let removableMediaLockHintText = "Editable when stopped or running"

    /// Whether this VM's removable-media list takes an edit right now.
    ///
    /// Wider than ``canEditStorageDisks``: the media are hot-pluggable, so a
    /// live guest takes an edit that a suspended VM's pinned device set cannot.
    private var canEditRemovableMedia: Bool {
        viewModel.capabilities.isAvailable(.editRemovableMedia, on: instance)
    }

    private var fileMonitorLoop: ObservationLoop?

    private let reorderSheetPresenter = SheetPresenter()
    private let attachmentInfoPresenter = PopoverPresenter()
    private lazy var storageDiskCoordinator = DiskSizePopoverCoordinator(
        headline: "Create New Disk",
        caption:
            "Creates an ASIF sparse disk image inside the VM bundle. Physical size grows as data is written.",
        onConfirm: { [weak self] sizeInGB in
            guard let self else { return }
            let instance = self.instance
            Task { [weak self] in
                await self?.viewModel.createStorageDisk(for: instance, sizeInGB: sizeInGB)
            }
        }
    )
    private lazy var removableMediaCoordinator = DiskSizePopoverCoordinator(
        headline: "Create New Removable Disk",
        caption:
            "Creates a writable ASIF sparse disk image at a location you choose, attached as a hot-pluggable USB drive. The file lives outside the VM bundle.",
        onConfirm: { [weak self] sizeInGB in
            self?.presentRemovableSavePanel(sizeInGB: sizeInGB)
        }
    )

    // Storage Disks
    private var storageListStack = NSStackView()
    private var attachStorageButton = NSButton()
    private var createStorageButton = NSButton()
    private var editBootOrderButton = NSButton()
    /// The Storage Disks rows and the diff behind them, rebuilt with the
    /// section's list stack.
    private var storageList: AttachmentList?

    // Removable Media
    private var removableListStack = NSStackView()
    private var createRemovableButton: NSButton?
    /// The Removable Media rows, on the same terms as ``storageList``.
    private var removableList: AttachmentList?

    /// One attachment list: its rows, its rendered snapshot and its edit gate.
    private typealias AttachmentList = VMSettingsKeyedListController<
        VMSettingsRenderedRow, AttachmentRowView
    >

    /// The list serving `kind`, which is what a per-kind row, edit-gate or
    /// rebuild question resolves to.
    private func list(_ kind: AttachmentKind) -> AttachmentList? {
        switch kind {
        case .storage: storageList
        case .removable: removableList
        }
    }

    // MARK: - Read accessors (materialize defaults)

    private var currentStorageDisks: [StorageDisk] {
        instance.effectiveStorageDisks
    }

    private var currentRemovableMedia: [RemovableMediaItem] {
        instance.configuration.removableMedia ?? []
    }

    /// Re-renders both lists whenever a watched path appears or disappears, so
    /// the missing-file affordance on attachment rows stays live.
    private func armFileMonitorLoop() {
        fileMonitorLoop?.cancel()
        fileMonitorLoop = observeRecurring(
            track: { [monitor = context.fileMonitor] in _ = monitor.existsByPath },
            apply: { [weak self] in
                self?.refreshStorageList()
                self?.refreshRemovableList()
            })
    }

    // MARK: Storage Disks

    private func buildStorageSection() -> NSView {
        storageListStack = makeGroupedFormListStack()
        storageList = AttachmentList(listStack: storageListStack)
        attachStorageButton = makeGroupedFormPushButton(
            "Attach Disk…", target: self, action: #selector(attachStorageTapped))
        createStorageButton = makeGroupedFormPushButton(
            "Create New Disk…", target: self, action: #selector(createStorageTapped))
        editBootOrderButton = makeGroupedFormPushButton(
            "Edit Boot Order…", target: self, action: #selector(editBootOrderTapped))

        let buttonRow = lockRegistry.lockable(
            makeGroupedFormButtonRow([attachStorageButton, createStorageButton, editBootOrderButton]),
            attachStorageButton, createStorageButton, editBootOrderButton)
        let card = makeGroupedFormCard(rows: [storageListStack, buttonRow])

        let paragraphs: [InfoPopoverParagraph] =
            instance.configuration.guestOS == .linux
            ? [
                .body(
                    "Position 1 boots first on EFI guests; on Linux Kernel boot, position affects device enumeration but not boot priority."
                ),
                .body("Permanent disks attach as virtio block devices (`/dev/vda`, `/dev/vdb`, …)."),
                .body(
                    "Installer images (.iso, .dmg) attach as USB Mass Storage entries on this list — still bootable, separate from hot-pluggable Removable Media — so reordering an installer doesn't change your main disk's `/dev/vda` letter."
                ),
            ]
            : [
                .body("Position 1 is the main system disk; subsequent positions follow in order."),
                .body("Permanent disks attach as virtio block devices."),
                .body(
                    "Installer images (.iso, .dmg) attach as USB Mass Storage entries on this list — still bootable, separate from hot-pluggable Removable Media."
                ),
            ]
        return makeGroupedFormSection([
            lockRegistry.makeHeader(
                "Storage Disks", lockable: true, paragraphs: paragraphs,
                lockHintSink: { [weak self] hint in
                    self?.storageLockHintView = hint
                    self?.storageLockHintLabel = hint.subviews.compactMap { $0 as? NSTextField }.first
                }), card,
        ])
    }

    // MARK: Removable Media

    private func buildRemovableMediaSection() -> NSView {
        removableListStack = makeGroupedFormListStack()
        removableList = AttachmentList(
            listStack: removableListStack, emptyMessage: "No removable media attached")
        let attach = makeGroupedFormPushButton("Attach Disk…", target: self, action: #selector(attachRemovableTapped))
        let create = makeGroupedFormPushButton(
            "Create New Disk…", target: self, action: #selector(createRemovableTapped))
        createRemovableButton = create
        let buttonRow = removableLockRegistry.lockable(
            makeGroupedFormButtonRow([attach, create]), attach, create)
        let card = makeGroupedFormCard(rows: [removableListStack, buttonRow])

        let firstParagraph: InfoPopoverParagraph =
            instance.configuration.guestOS == .linux
            ? .body(
                "Appears as a USB Mass Storage device (typically `/dev/sda` or similar). Most desktop distros auto-mount; headless installs need an explicit `mount`."
            )
            : .body("Appears as a removable USB drive in Finder; auto-mounts.")
        return makeGroupedFormSection([
            removableLockRegistry.makeHeader(
                "Removable Media",
                lockable: true,
                lockHintText: Self.removableMediaLockHintText,
                paragraphs: [
                    firstParagraph,
                    .body(
                        "Hot-pluggable — changes take effect immediately while the VM is running. For boot media, use Storage Disks instead."
                    ),
                ]), card,
        ])
    }

    // MARK: - Refresh

    private func refreshStorageList() {
        let disks = currentStorageDisks
        editBootOrderButton.isHidden = disks.count <= 1
        let models = disks.map { disk -> VMSettingsRenderedRow in
            let isMissing = !disk.isInternal && !context.fileMonitor.exists(disk.path)
            return VMSettingsRenderedRow(
                id: disk.id,
                iconSystemName: diskIconSystemName(for: disk),
                title: disk.label,
                notes: disk.notes,
                // Structural subtitle only — the live size is read off-main and
                // filled in by `populate`, so it isn't part of the rebuild diff.
                subtitle: disk.isInternal ? "In-bundle disk image" : disk.path,
                isMissing: isMissing,
                missingPath: isMissing ? disk.path : nil,
                readOnly: disk.readOnly,
                controlsEnabled: canEditStorageDisks)
        }
        storageList?.update(
            models,
            readsUnchangedRows: sizesCanMove,
            makeRow: { model in
                makeAttachmentRow(
                    model: model, kind: .storage,
                    readOnlySelector: #selector(storageReadOnlyToggled))
            },
            applyRow: applyAttachmentRow,
            readLiveSubtitle: { model, row in
                guard let disk = currentStorageDisks.first(where: { $0.id == model.id })
                else { return }
                populateDiskSubtitle(
                    row.subtitleField, for: disk, bundleLayout: instance.bundleLayout,
                    isMissing: model.isMissing)
            })
    }

    private func refreshRemovableList() {
        let items = currentRemovableMedia
        let models = items.map { item -> VMSettingsRenderedRow in
            let isMissing = !context.fileMonitor.exists(item.path)
            return VMSettingsRenderedRow(
                id: item.id,
                iconSystemName: "opticaldisc",
                title: item.label,
                notes: item.notes,
                subtitle: item.path,
                isMissing: isMissing,
                missingPath: isMissing ? item.path : nil,
                readOnly: item.readOnly,
                controlsEnabled: canEditRemovableMedia)
        }
        removableList?.update(
            models,
            readsUnchangedRows: sizesCanMove,
            makeRow: { model in
                makeAttachmentRow(
                    model: model, kind: .removable,
                    readOnlySelector: #selector(removableReadOnlyToggled))
            },
            applyRow: applyAttachmentRow,
            readLiveSubtitle: { model, row in
                guard let item = currentRemovableMedia.first(where: { $0.id == model.id })
                else { return }
                populateDiskSubtitle(
                    row.subtitleField, for: item, bundleLayout: instance.bundleLayout,
                    isMissing: model.isMissing)
            })
    }

    /// Whether a row's size can have moved without anything about the row
    /// changing.
    ///
    /// The size behind a row is a filesystem walk, so it is re-read on every
    /// pass only while the guest is running and writing to the disk. A stopped
    /// VM's sizes cannot move on their own, so those rows are re-read when
    /// something about them changed and not otherwise.
    private var sizesCanMove: Bool {
        instance.status == .running
    }

    private func applyAttachmentRow(_ model: VMSettingsRenderedRow, to row: AttachmentRowView) {
        row.update(
            title: model.title, notes: model.notes, iconSystemName: model.iconSystemName,
            missingPath: model.missingPath, readOnly: model.readOnly,
            controlsEnabled: model.controlsEnabled)
    }

    private func refresh(_ kind: AttachmentKind) {
        switch kind {
        case .storage: refreshStorageList()
        case .removable: refreshRemovableList()
        }
    }

    /// Builds one attachment row, wiring its icon Get Info, rename/notes
    /// closures, and context menu; the per-list differences arrive via `kind`
    /// and `readOnlySelector`.
    private func makeAttachmentRow(
        model: VMSettingsRenderedRow,
        kind: AttachmentKind,
        readOnlySelector: Selector
    ) -> AttachmentRowView {
        let ref = AttachmentRef(kind: kind, id: model.id)
        let icon = AttachmentIconButton()
        icon.configure(systemName: model.iconSystemName, missingPath: model.missingPath)
        icon.onActivate = { [weak self] anchor in
            guard let self, let info = self.attachmentInfo(ref) else { return }
            self.presentAttachmentInfoPopover(info, for: ref, from: anchor)
        }
        // Removable media is hot-pluggable and swapped often, so it carries an
        // inline one-click Eject button (detach only, no confirmation); storage
        // disks detach through the context menu alone.
        let ejectButton: NSButton? =
            kind == .removable
            ? makeGroupedFormEjectButton(
                id: model.id, enabled: model.controlsEnabled, target: self,
                action: #selector(removableEjectTapped))
            : nil
        let row = AttachmentRowView(
            itemID: model.id,
            title: model.title,
            notes: model.notes,
            controlsEnabled: model.controlsEnabled,
            icon: icon,
            subtitle: makeAttachmentSubtitleLabel(path: "", isMissing: false),
            readOnlyToggle: makeGroupedFormReadOnlySwitch(
                id: model.id, isOn: model.readOnly, enabled: model.controlsEnabled,
                target: self, action: readOnlySelector),
            readOnlyCaption: makeGroupedFormReadOnlyCaption(),
            ejectButton: ejectButton)
        row.onEditBegan = { [weak self] id in self?.list(kind)?.activeEdit = id }
        row.onRenameCommitted = { [weak self] _, newLabel in
            self?.commitAttachmentRename(ref, newLabel: newLabel)
        }
        row.onRenameCancelled = { [weak self] _ in
            self?.clearActiveEdit(kind)
            self?.refresh(kind)
        }
        row.onNotesCommitted = { [weak self] _, notes in
            self?.commitAttachmentNotes(ref, notes: notes)
        }
        row.onNotesCancelled = { [weak self] _ in
            self?.clearActiveEdit(kind)
            self?.refresh(kind)
        }
        // A note the row can't hold on one line is edited where it fits. Looked
        // up fresh (not captured) so the closure doesn't hold the row it lives on.
        row.onNotesOverflowActivated = { [weak self] _ in
            guard let self, let info = self.attachmentInfo(ref), let anchor = self.attachmentRow(ref)
            else { return }
            self.presentAttachmentInfoPopover(info, for: ref, from: anchor.infoAnchor)
        }
        row.contextMenu = { [weak self] in self?.buildAttachmentContextMenu(ref) }
        return row
    }

    /// Commits an inline rename for either list, deferred to the next runloop
    /// turn so the field editor's end-editing callback fully unwinds before the
    /// config-change rebuild tears down and recreates the editing row.
    ///
    /// The instance is pinned before the `Task`: the commit can be triggered by
    /// the same outside-click that selects another VM, and `reconfigure` rebinds
    /// `self.instance` synchronously, so reading `self.instance` once the Task
    /// runs would commit into whichever VM is showing by then.
    private func commitAttachmentRename(_ ref: AttachmentRef, newLabel: String) {
        clearActiveEdit(ref.kind)
        let instance = instance
        Task { [weak self] in
            guard let self else { return }
            switch ref.kind {
            case .storage:
                self.viewModel.renameStorageDisk(ref.id, newLabel: newLabel, on: instance)
            case .removable:
                self.viewModel.renameRemovableMedia(ref.id, newLabel: newLabel, on: instance)
            }
            // A no-op rename (empty / unchanged) fires no observation, so force a
            // refresh to pick up any size update suppressed during the edit.
            self.refresh(ref.kind)
        }
    }

    /// Commits an inline note edit for either list, on the same deferred-Task
    /// shape (and instance-pinning) as ``commitAttachmentRename(_:newLabel:)``.
    private func commitAttachmentNotes(_ ref: AttachmentRef, notes: String) {
        clearActiveEdit(ref.kind)
        let instance = instance
        Task { [weak self] in
            guard let self else { return }
            switch ref.kind {
            case .storage:
                self.viewModel.setStorageDiskNotes(ref.id, notes: notes, on: instance)
            case .removable:
                self.viewModel.setRemovableMediaNotes(ref.id, notes: notes, on: instance)
            }
            self.refresh(ref.kind)
        }
    }

    private func clearActiveEdit(_ kind: AttachmentKind) {
        list(kind)?.activeEdit = nil
    }

    /// Whether that list has an inline edit open — Rename and Edit Notes on a
    /// row have to wait for it, same hazard
    /// ``SnapshotSectionView/makeRowMenu(for:canRevert:canDelete:isBaseline:)``
    /// guards against.
    private func hasActiveEdit(_ kind: AttachmentKind) -> Bool {
        list(kind)?.activeEdit != nil
    }

    // MARK: Storage

    @objc private func attachStorageTapped() {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM", allowsMultipleSelection: true)
        guard !urls.isEmpty else { return }
        viewModel.attachStorageDisks(urls.map(PickedFile.init(picking:)), to: instance)
    }

    @objc private func createStorageTapped() {
        storageDiskCoordinator.show(from: createStorageButton)
    }

    @objc private func editBootOrderTapped() {
        guard let window = view.window else { return }
        let sheet = StorageDiskReorderSheetContentViewController(
            disks: currentStorageDisks, instance: instance, fileMonitor: context.fileMonitor)
        sheet.delegate = self
        reorderSheetPresenter.show(content: sheet, in: window)
    }

    @objc private func storageReadOnlyToggled(_ sender: NSSwitch) {
        guard let id = attachmentUUID(from: sender) else { return }
        setStorageReadOnly(sender.state == .on, forDiskID: id)
    }

    private func setStorageReadOnly(_ readOnly: Bool, forDiskID id: UUID) {
        viewModel.setStorageDiskReadOnly(id, readOnly: readOnly, on: instance)
    }

    private func presentStorageDeleteConfirmation(forDiskID id: UUID) {
        let instance = instance
        Task { [weak self] in
            guard let self, let disk = currentStorageDisks.first(where: { $0.id == id })
            else { return }
            // Internal (bundle-relative) disks are per-VM, so they're never
            // shared; only resolve sharing for external disks.
            var shared: [String] = []
            if !disk.isInternal {
                shared = await viewModel.sharingVMNames(
                    forPath: disk.path, bookmark: disk.bookmark, excluding: instance)
            }
            // The resolve suspends, so the panel may have rebuilt or closed
            // under it — re-read the window and the row before presenting.
            guard let window = view.window,
                let disk = currentStorageDisks.first(where: { $0.id == id })
            else { return }
            let prompt = VMCommandCore.attachmentDeletePrompt(
                label: disk.label,
                isInternal: disk.isInternal,
                isGuestAgent: false,
                sharedVMNames: shared)
            presentSheetAlert(
                makeDeleteAlert(prompt: prompt) { [weak self] trashFile in
                    Task { [weak self] in
                        await self?.viewModel.removeStorageDisk(
                            disk.id, from: instance, trashFile: trashFile)
                    }
                },
                in: window)
        }
    }

    // MARK: Attachment context menu (shared by both lists)

    /// Identifies which list a context-menu item / row belongs to, so a single
    /// set of `@objc` handlers serves both lists.
    enum AttachmentKind { case storage, removable }

    /// A context-menu item's backing identity (list + id), stored as its
    /// `representedObject`.
    final class AttachmentRef: NSObject {
        let kind: AttachmentKind
        let id: UUID
        init(kind: AttachmentKind, id: UUID) {
            self.kind = kind
            self.id = id
        }
    }

    /// A normalized read of an attachment's current state, so the shared menu /
    /// Get Info / Finder actions don't branch on kind.
    private struct AttachmentInfo {
        let id: UUID
        let label: String
        let path: String
        let isInternal: Bool
        let readOnly: Bool
        let busText: String
        let notes: String
        /// Rename / Read Only / Remove gating, read from the capability the
        /// verb behind each of them refuses on.
        let editable: Bool
        /// The VM's only storage disk, which the removal verb refuses — so its
        /// row offers no Remove….
        let isSoleStorageDisk: Bool
    }

    private func attachmentInfo(_ ref: AttachmentRef) -> AttachmentInfo? {
        switch ref.kind {
        case .storage:
            guard let disk = currentStorageDisks.first(where: { $0.id == ref.id }) else { return nil }
            return AttachmentInfo(
                id: disk.id, label: disk.label, path: disk.path, isInternal: disk.isInternal,
                readOnly: disk.readOnly,
                busText: disk.kind == .usbMassStorage ? "USB mass storage" : "Virtio block",
                notes: disk.notes, editable: canEditStorageDisks,
                isSoleStorageDisk: instance.isSoleStorageDisk(disk))
        case .removable:
            guard let item = currentRemovableMedia.first(where: { $0.id == ref.id }) else { return nil }
            return AttachmentInfo(
                id: item.id, label: item.label, path: item.path, isInternal: false,
                readOnly: item.readOnly, busText: "USB mass storage", notes: item.notes,
                editable: canEditRemovableMedia, isSoleStorageDisk: false)
        }
    }

    private func attachmentRow(_ ref: AttachmentRef) -> AttachmentRowView? {
        list(ref.kind)?.row(ref.id)
    }

    /// Absolute URL backing an attachment, via the single resolution rule in
    /// ``VMBundleLayout/diskURL(forRelativePath:isInternal:)``.
    private func attachmentURL(_ info: AttachmentInfo) -> URL {
        instance.bundleLayout.diskURL(forRelativePath: info.path, isInternal: info.isInternal)
    }

    /// Builds the right-click menu for an attachment row, lazily at click time so
    /// it reflects current state (the Read Only checkmark, missing-file disabling).
    private func buildAttachmentContextMenu(_ ref: AttachmentRef) -> NSMenu? {
        guard let info = attachmentInfo(ref) else { return nil }
        let menu = NSMenu()
        // We manage enablement explicitly (rename/remove gated by read-only lock,
        // Show in Finder by file presence), so opt out of auto-validation.
        menu.autoenablesItems = false

        let noEditInFlight = !hasActiveEdit(ref.kind)
        let rename = attachmentMenuItem("Rename", #selector(menuAttachmentRename(_:)), ref)
        rename.isEnabled = info.editable && noEditInFlight
        menu.addItem(rename)
        let editNotes = attachmentMenuItem("Edit Notes", #selector(menuAttachmentEditNotes(_:)), ref)
        editNotes.isEnabled = info.editable && noEditInFlight
        menu.addItem(editNotes)
        menu.addItem(attachmentMenuItem("Get Info", #selector(menuAttachmentGetInfo(_:)), ref))

        menu.addItem(.separator())

        let showInFinder = attachmentMenuItem(
            "Show in Finder", #selector(menuAttachmentShowInFinder(_:)), ref)
        // Nothing to reveal when an external file is missing (in-bundle always exists).
        showInFinder.isEnabled = info.isInternal || context.fileMonitor.exists(info.path)
        menu.addItem(showInFinder)
        menu.addItem(attachmentMenuItem("Copy Path", #selector(menuAttachmentCopyPath(_:)), ref))
        menu.addItem(
            attachmentMenuItem("Copy File Name", #selector(menuAttachmentCopyFileName(_:)), ref))

        menu.addItem(.separator())

        let readOnly = attachmentMenuItem(
            "Read Only", #selector(menuAttachmentToggleReadOnly(_:)), ref)
        readOnly.state = info.readOnly ? .on : .off
        readOnly.isEnabled = info.editable
        menu.addItem(readOnly)
        // Removable media offers Eject (detach, no confirmation) alongside the
        // file-trashing Remove…; storage disks get Remove… only.
        if ref.kind == .removable {
            let eject = attachmentMenuItem("Eject", #selector(menuAttachmentEject(_:)), ref)
            eject.isEnabled = info.editable
            menu.addItem(eject)
        }
        // No Remove… on a VM's only disk: the verb refuses, and an item that
        // could only raise that refusal is noise.
        if !info.isSoleStorageDisk {
            let remove = attachmentMenuItem("Remove…", #selector(menuAttachmentRemove(_:)), ref)
            remove.isEnabled = info.editable
            menu.addItem(remove)
        }

        return menu
    }

    private func attachmentMenuItem(_ title: String, _ action: Selector, _ ref: AttachmentRef)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = ref
        return item
    }

    private func attachmentRef(from sender: NSMenuItem) -> AttachmentRef? {
        sender.representedObject as? AttachmentRef
    }

    @objc private func menuAttachmentRename(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender) else { return }
        attachmentRow(ref)?.beginRename()
    }

    @objc private func menuAttachmentEditNotes(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender) else { return }
        attachmentRow(ref)?.beginNotesEditing()
    }

    @objc private func menuAttachmentShowInFinder(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([attachmentURL(info)])
    }

    @objc private func menuAttachmentCopyPath(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref) else { return }
        copyToPasteboard(attachmentURL(info).path(percentEncoded: false))
    }

    @objc private func menuAttachmentCopyFileName(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref) else { return }
        copyToPasteboard(attachmentURL(info).lastPathComponent)
    }

    @objc private func menuAttachmentToggleReadOnly(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref) else { return }
        switch ref.kind {
        case .storage: setStorageReadOnly(!info.readOnly, forDiskID: ref.id)
        case .removable: setRemovableReadOnly(!info.readOnly, forItemID: ref.id)
        }
    }

    @objc private func menuAttachmentEject(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), ref.kind == .removable else { return }
        ejectRemovableMedia(forItemID: ref.id)
    }

    @objc private func menuAttachmentRemove(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender) else { return }
        switch ref.kind {
        case .storage: presentStorageDeleteConfirmation(forDiskID: ref.id)
        case .removable: presentRemovableDeleteConfirmation(forItemID: ref.id)
        }
    }

    @objc private func menuAttachmentGetInfo(_ sender: NSMenuItem) {
        guard let ref = attachmentRef(from: sender), let info = attachmentInfo(ref),
            let row = attachmentRow(ref)
        else { return }
        presentAttachmentInfoPopover(info, for: ref, from: row.infoAnchor)
    }

    /// Get Info popover for either list.
    ///
    /// Reads the on-disk/allocated figures and creation date **off the main
    /// thread** — the file may live on a slow or sleeping external volume — then
    /// presents when they land.
    private func presentAttachmentInfoPopover(
        _ info: AttachmentInfo, for ref: AttachmentRef, from anchor: NSView
    ) {
        let url = attachmentURL(info)
        let layout = instance.bundleLayout
        let path = info.path
        let isInternal = info.isInternal
        Task { [weak self] in
            let snapshot = await Task.detached {
                () -> (VMBundleLayout.DiskSizes, Date?) in
                let sizes = layout.diskSizes(forRelativePath: path, isInternal: isInternal)
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                return (sizes, created)
            }.value
            // Don't present onto a settings pane the user has navigated away from
            // while the off-main read was in flight (the VC is reused across
            // route changes, so `[weak self]` alone isn't enough).
            guard let self, !self.context.isDismissed else { return }
            let (sizes, created) = snapshot
            let content = AttachmentInfoPopoverContentViewController(
                label: info.label,
                fileName: url.lastPathComponent,
                fullPath: url.path(percentEncoded: false),
                onDiskText: sizes.onDiskBytes.map { DataFormatters.formatBytes($0) } ?? "—",
                allocatedText: sizes.capacityBytes.map { DataFormatters.formatBytes($0) } ?? "Unknown",
                readOnly: info.readOnly,
                busText: info.busText,
                createdText: created.map { Self.diskInfoDateFormatter.string(from: $0) } ?? "Unknown",
                notes: info.notes,
                canEdit: info.editable,
                onCommitNotes: { [weak self] notes in
                    guard let self else { return }
                    // Looked up fresh: the popover outlives edits landing from
                    // elsewhere, and the copy it was built with can be stale.
                    self.commitAttachmentNotes(ref, notes: notes)
                })
            content.onRequestClose = { [weak self] in self?.attachmentInfoPresenter.close() }
            self.attachmentInfoPresenter.show(content: content, from: anchor, preferredEdge: .minY)
        }
    }

    private static let diskInfoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Builds the alert for a decided ``AttachmentDeletePrompt``, appending Cancel.
    private func makeDeleteAlert(
        prompt: AttachmentDeletePrompt,
        perform: @escaping (_ trashFile: Bool) -> Void
    ) -> AlertConfiguration {
        var buttons: [AlertButton] = prompt.actions.map { action in
            switch action {
            case .moveToTrash:
                return AlertButton("Move to Trash", role: .destructive) { perform(true) }
            case .removeFromVM:
                return AlertButton("Remove from VM", role: .default) { perform(false) }
            }
        }
        buttons.append(AlertButton("Cancel", role: .cancel))
        return AlertConfiguration(title: prompt.title, message: prompt.message, buttons: buttons)
    }

    // MARK: Removable

    @objc private func attachRemovableTapped() {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM", allowsMultipleSelection: true)
        guard !urls.isEmpty else { return }
        viewModel.attachRemovableMedia(urls.map(PickedFile.init(picking:)), to: instance)
    }

    @objc private func createRemovableTapped() {
        guard let createRemovableButton else { return }
        removableMediaCoordinator.show(from: createRemovableButton)
    }

    @objc private func removableReadOnlyToggled(_ sender: NSSwitch) {
        guard let id = attachmentUUID(from: sender) else { return }
        setRemovableReadOnly(sender.state == .on, forItemID: id)
    }

    private func setRemovableReadOnly(_ readOnly: Bool, forItemID id: UUID) {
        viewModel.setRemovableMediaReadOnly(id, readOnly: readOnly, on: instance)
    }

    /// Ejects a removable medium from its inline trailing button.
    ///
    /// Detach only — no confirmation, backing file untouched.
    @objc private func removableEjectTapped(_ sender: NSButton) {
        guard let id = attachmentUUID(from: sender) else { return }
        ejectRemovableMedia(forItemID: id)
    }

    /// Detaches a removable medium (removes its config entry, keeping the file).
    ///
    /// Dropping the `removableMedia` entry is what the live reconcile
    /// hot-detaches from a running VM. No alert: ejecting is reversible.
    private func ejectRemovableMedia(forItemID id: UUID) {
        viewModel.ejectRemovableMedia(id, from: instance)
    }

    private func presentRemovableDeleteConfirmation(forItemID id: UUID) {
        let instance = instance
        Task { [weak self] in
            guard let self, let item = currentRemovableMedia.first(where: { $0.id == id })
            else { return }
            let isAgent = item.isBundledGuestAgentInstaller
            var shared: [String] = []
            if !isAgent {
                shared = await viewModel.sharingVMNames(
                    forPath: item.path, bookmark: item.bookmark, excluding: instance)
            }
            // The resolve suspends, so the panel may have rebuilt or closed
            // under it — re-read the window and the row before presenting.
            guard let window = view.window,
                let item = currentRemovableMedia.first(where: { $0.id == id })
            else { return }
            let prompt = VMCommandCore.attachmentDeletePrompt(
                label: item.label,
                isInternal: false,
                isGuestAgent: isAgent,
                sharedVMNames: shared)
            presentSheetAlert(
                makeDeleteAlert(prompt: prompt) { [weak self] trashFile in
                    Task { [weak self] in
                        await self?.viewModel.removeRemovableMedia(
                            item.id, from: instance, trashFile: trashFile)
                    }
                },
                in: window)
        }
    }

    private func presentRemovableSavePanel(sizeInGB: Int) {
        let panel = NSSavePanel()
        panel.title = "Save Removable Disk"
        panel.message = "Choose where to save the new removable disk image."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "\(instance.name) Removable Disk.asif"
        panel.allowedContentTypes = [.asif]
        panel.canCreateDirectories = true
        let instance = instance
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { [weak self] in
                await self?.viewModel.createRemovableMedia(
                    for: instance, sizeInGB: sizeInGB, destinationURL: url)
            }
        }
    }
}

// MARK: - StorageDiskReorderSheetContentViewControllerDelegate

extension VMSettingsStoragePanelViewController:
    StorageDiskReorderSheetContentViewControllerDelegate
{
    func storageDiskReorderSheet(
        _ vc: StorageDiskReorderSheetContentViewController, didReorderTo disks: [StorageDisk]
    ) {
        viewModel.reorderStorageDisks(disks.map(\.id), on: instance)
    }

    func storageDiskReorderSheetDidDismiss(_ vc: StorageDiskReorderSheetContentViewController) {
        reorderSheetPresenter.close()
    }
}
