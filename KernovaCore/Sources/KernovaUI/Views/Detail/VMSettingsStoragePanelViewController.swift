import AppKit
import KernovaAppKitShared
import KernovaCommandModel
import KernovaCore
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
            addGroupedFormFullWidth(section, to: panelStack)
        }
    }

    func refresh() {
        lockRegistry.apply(isReadOnly: !canEditStorageDisks)
        removableLockRegistry.apply(isReadOnly: !canEditRemovableMedia)
        createStorageButton.isEnabled = viewModel.capabilities.isAvailable(.createStorageDisk, on: instance)
        createRemovableButton?.isEnabled = viewModel.capabilities.isAvailable(
            .createRemovableMedia, on: instance)
        refreshStorageList()
        refreshRemovableList()
        bootOrderSheet?.show(sizes: attachmentSizes, missing: missingStorageDiskIDs)
    }

    func prepareForDisappearance() {
        if reorderSheetPresenter.isShown { reorderSheetPresenter.close() }
        if attachmentInfoPresenter.isShown { attachmentInfoPresenter.close() }
        // Drop any in-flight inline edit so the flag can't pin a list in a
        // suppressed (never-rebuilds) state across an appear/disappear cycle.
        storageList?.activeEdit = nil
        removableList?.activeEdit = nil
    }

    /// Whether this VM's disk list takes an edit right now.
    private var canEditStorageDisks: Bool {
        viewModel.capabilities.isAvailable(.editStorageDisks, on: instance)
    }

    /// Whether this VM's removable-media list takes an edit right now.
    ///
    /// Wider than ``canEditStorageDisks``: the media are hot-pluggable, so a
    /// live guest takes an edit that a suspended VM's pinned device set cannot.
    private var canEditRemovableMedia: Bool {
        viewModel.capabilities.isAvailable(.editRemovableMedia, on: instance)
    }

    private let reorderSheetPresenter = SheetPresenter()
    /// The Boot Order sheet while it is up, which states the sizes the rows do.
    private weak var bootOrderSheet: StorageDiskReorderSheetContentViewController?
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

    /// The storage disks whose files the pane's monitor reports missing.
    private var missingStorageDiskIDs: Set<UUID> {
        Set(currentStorageDisks.filter { isMissing($0) }.map(\.id))
    }

    private func isMissing(_ disk: StorageDisk) -> Bool {
        !disk.isInternal && !context.fileMonitor.exists(disk.path)
    }

    /// Every attachment's sizes as the pane last measured them.
    private var attachmentSizes: [UUID: VMBundleLayout.DiskSizes] {
        context.overview.resolved.attachmentSizes
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

        // Create is its own operation, enabled by ``refresh()`` from its own
        // capability; the row still dims with the section's lock.
        let buttonRow = lockRegistry.lockable(
            makeGroupedFormButtonRow([attachStorageButton, createStorageButton, editBootOrderButton]),
            attachStorageButton, editBootOrderButton)
        let card = makeGroupedFormCard(rows: [storageListStack, buttonRow])

        let paragraphs: [InfoPopoverParagraph] =
            instance.configuration.guestOS == .linux
            ? [
                .body("Permanent disks attach as virtio block devices (`/dev/vda`, `/dev/vdb`, …)."),
                .body(
                    "Installer images (.iso, .dmg) attach as USB Mass Storage entries on this list — still bootable, separate from hot-pluggable Removable Media — so reordering an installer doesn't change your main disk's `/dev/vda` letter."
                ),
            ]
            : [
                .body("Permanent disks attach as virtio block devices."),
                .body(
                    "Installer images (.iso, .dmg) attach as USB Mass Storage entries on this list — still bootable, separate from hot-pluggable Removable Media."
                ),
            ]
        return makeGroupedFormSection([
            lockRegistry.makeHeader("Storage Disks", editableWhen: .stopped, paragraphs: paragraphs), card,
        ])
    }

    // MARK: Removable Media

    private func buildRemovableMediaSection() -> NSView {
        removableListStack = makeGroupedFormListStack()
        removableList = AttachmentList(
            listStack: removableListStack, emptyMessage: "No removable media")
        let attach = makeGroupedFormPushButton("Attach Disk…", target: self, action: #selector(attachRemovableTapped))
        let create = makeGroupedFormPushButton(
            "Create New Disk…", target: self, action: #selector(createRemovableTapped))
        createRemovableButton = create
        let buttonRow = removableLockRegistry.lockable(makeGroupedFormButtonRow([attach, create]), attach)
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
                editableWhen: .stoppedOrRunning,
                paragraphs: [firstParagraph, .body("For boot media, use Storage Disks instead.")]), card,
        ])
    }

    // MARK: - Refresh

    private func refreshStorageList() {
        let disks = currentStorageDisks
        editBootOrderButton.isHidden = disks.count <= 1
        let sizes = attachmentSizes
        let models = disks.map { disk -> VMSettingsRenderedRow in
            let isMissing = self.isMissing(disk)
            return VMSettingsRenderedRow(
                id: disk.id,
                iconSystemName: diskIconSystemName(for: disk),
                title: disk.label,
                notes: disk.notes,
                subtitle: VMBundleLayout.DiskSizes.subtitle(of: disk.imageReference, measured: sizes[disk.id]),
                isMissing: isMissing,
                missingPath: isMissing ? disk.path : nil,
                readOnly: disk.readOnly,
                controlsEnabled: canEditStorageDisks,
                ejectEnabled: canEditStorageDisks)
        }
        storageList?.update(
            models,
            makeRow: { model in
                makeAttachmentRow(
                    model: model, kind: .storage,
                    readOnlySelector: #selector(storageReadOnlyToggled))
            },
            applyRow: applyAttachmentRow)
    }

    private func refreshRemovableList() {
        let items = currentRemovableMedia
        let sizes = attachmentSizes
        let models = items.map { item -> VMSettingsRenderedRow in
            let isMissing = !context.fileMonitor.exists(item.path)
            return VMSettingsRenderedRow(
                id: item.id,
                iconSystemName: "opticaldisc",
                title: item.label,
                notes: item.notes,
                subtitle: VMBundleLayout.DiskSizes.subtitle(of: item.imageReference, measured: sizes[item.id]),
                isMissing: isMissing,
                missingPath: isMissing ? item.path : nil,
                readOnly: item.readOnly,
                controlsEnabled: canEditRemovableMedia,
                ejectEnabled: canEditRemovableMedia)
        }
        removableList?.update(
            models,
            makeRow: { model in
                makeAttachmentRow(
                    model: model, kind: .removable,
                    readOnlySelector: #selector(removableReadOnlyToggled))
            },
            applyRow: applyAttachmentRow)
    }

    private func applyAttachmentRow(_ model: VMSettingsRenderedRow, to row: AttachmentRowView) {
        row.update(
            title: model.title, notes: model.notes, subtitle: model.subtitle,
            iconSystemName: model.iconSystemName, missingPath: model.missingPath,
            readOnly: model.readOnly, controlsEnabled: model.controlsEnabled,
            ejectEnabled: model.ejectEnabled)
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
                id: model.id, enabled: model.ejectEnabled, target: self,
                action: #selector(removableEjectTapped))
            : nil
        let row = AttachmentRowView(
            itemID: model.id,
            title: model.title,
            notes: model.notes,
            controlsEnabled: model.controlsEnabled,
            icon: icon,
            subtitle: makeAttachmentSubtitleLabel(
                path: model.missingPath ?? model.subtitle, isMissing: model.isMissing),
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
            // refresh to land any rebuild the edit deferred.
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
    /// ``SnapshotSectionView/makeRowMenu(for:canRevert:canRename:canSetNotes:canDelete:)``
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
            disks: currentStorageDisks, sizes: attachmentSizes, missing: missingStorageDiskIDs)
        sheet.onReorder = { [weak self] disks in
            guard let self else { return }
            viewModel.reorderStorageDisks(disks.map(\.id), on: instance)
        }
        sheet.onDone = { [weak self] in self?.reorderSheetPresenter.close() }
        bootOrderSheet = sheet
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
            let remove: (Bool) -> Void = { [weak self] trashFile in
                Task { [weak self] in
                    await self?.viewModel.removeStorageDisk(
                        disk.id, from: instance, trashFile: trashFile)
                }
            }
            // A `removeAttachment` confirm trashes the file exactly when it is
            // destructive, so a detach-only confirm keeps it — the promise its
            // own copy makes, whether or not the sharing that decided it still
            // holds by the time the user answers.
            presentSheetAlert(
                AlertConfiguration(
                    confirming: prompt,
                    confirm: { remove(prompt.confirmIsDestructive) },
                    alternative: { remove(!$0.keepsFile) }),
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
        let image: DiskImageReference
        let readOnly: Bool
        let busText: String
        let notes: String
        /// Rename / Read Only / Eject gating, read from the capability the
        /// verb behind each of them refuses on.
        let editable: Bool
        /// Remove… gating: a storage disk's removal can trash its file, so it
        /// reads the trashing removal's capability, which admits only where
        /// the entry-only removal does too.
        let removable: Bool
        /// The VM's only storage disk, which the removal verb refuses — so its
        /// row offers no Remove….
        let isSoleStorageDisk: Bool
    }

    private func attachmentInfo(_ ref: AttachmentRef) -> AttachmentInfo? {
        switch ref.kind {
        case .storage:
            guard let disk = currentStorageDisks.first(where: { $0.id == ref.id }) else { return nil }
            return AttachmentInfo(
                id: disk.id, label: disk.label, image: disk.imageReference,
                readOnly: disk.readOnly,
                busText: disk.kind == .usbMassStorage ? "USB mass storage" : "Virtio block",
                notes: disk.notes, editable: canEditStorageDisks,
                removable: viewModel.capabilities.isAvailable(.trashStorageDisk, on: instance),
                isSoleStorageDisk: instance.isSoleStorageDisk(disk))
        case .removable:
            guard let item = currentRemovableMedia.first(where: { $0.id == ref.id }) else { return nil }
            return AttachmentInfo(
                id: item.id, label: item.label, image: item.imageReference,
                readOnly: item.readOnly, busText: "USB mass storage", notes: item.notes,
                editable: canEditRemovableMedia, removable: canEditRemovableMedia,
                isSoleStorageDisk: false)
        }
    }

    private func attachmentRow(_ ref: AttachmentRef) -> AttachmentRowView? {
        list(ref.kind)?.row(ref.id)
    }

    /// Absolute URL backing an attachment, via the single resolution rule in
    /// ``VMBundleLayout/diskURL(forRelativePath:isInternal:)``.
    private func attachmentURL(_ info: AttachmentInfo) -> URL {
        instance.bundleLayout.diskURL(forRelativePath: info.image.path, isInternal: info.image.isInternal)
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
        showInFinder.isEnabled = info.image.isInternal || context.fileMonitor.exists(info.image.path)
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
            remove.isEnabled = info.removable
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
    /// presents when they land. Read here rather than taken from the pane's
    /// measurement: it is the detail asked for at this moment, and the pane
    /// measures no creation date.
    private func presentAttachmentInfoPopover(
        _ info: AttachmentInfo, for ref: AttachmentRef, from anchor: NSView
    ) {
        let url = attachmentURL(info)
        let layout = instance.bundleLayout
        let image = info.image
        Task { [weak self] in
            let snapshot = await Task.detached {
                layout.withDiskImage(image) { url -> (VMBundleLayout.DiskSizes, Date?) in
                    let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                    return (VMBundleLayout.diskSizes(at: url), created)
                }
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
                sizes: sizes,
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
            let isAgent = item.isInstaller(of: instance.bundleProducts.guestAgent)
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
            let remove: (Bool) -> Void = { [weak self] trashFile in
                Task { [weak self] in
                    await self?.viewModel.removeRemovableMedia(
                        item.id, from: instance, trashFile: trashFile)
                }
            }
            // Same rule as the storage rows: the confirm trashes only where the
            // prompt says it is destructive, so the Guest Agent installer and a
            // shared image are detached with their file left alone.
            presentSheetAlert(
                AlertConfiguration(
                    confirming: prompt,
                    confirm: { remove(prompt.confirmIsDestructive) },
                    alternative: { remove(!$0.keepsFile) }),
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
