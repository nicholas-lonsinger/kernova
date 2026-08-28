import AppKit
import UniformTypeIdentifiers
import os

/// The Storage category: the VM's disks and its hot-pluggable removable media.
///
/// Both lists are served by one set of row, menu and popover builders
/// parameterized by `AttachmentKind` and dispatching on an
/// `AttachmentRef(kind:id:)`, never a second implementation per list.
@MainActor
final class VMSettingsStoragePanelViewController: NSViewController, VMSettingsPanel {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "VMSettingsStoragePanel")

    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.storage
    private var lockRegistry = VMSettingsLockRegistry()

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
        rebuild()
    }

    // MARK: - Panel

    func rebuild() {
        loadViewIfNeeded()
        panelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockRegistry.removeAll()
        activeStorageEdit = nil
        activeRemovableEdit = nil
        storageRowsByID.removeAll()
        removableRowsByID.removeAll()
        renderedStorageRows = nil
        renderedRemovableRows = nil

        for section in [buildStorageSection(), buildRemovableMediaSection()] {
            panelStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
        }
        // The monitored paths are this instance's, so a rebuild re-seeds them.
        startInstanceSideEffects()
        let token = UUID()
        fileMonitorObservationToken = token
        observeFileMonitor(token: token)
    }

    func refresh() {
        lockRegistry.apply(isReadOnly: isReadOnly)
        refreshStorageList()
        refreshRemovableList()
        startInstanceSideEffects()
    }

    func prepareForDisappearance() {
        if reorderSheetPresenter.isShown { reorderSheetPresenter.close() }
        if attachmentInfoPresenter.isShown { attachmentInfoPresenter.close() }
        // Drop any in-flight inline edit so the flag can't pin a list in a
        // suppressed (never-rebuilds) state across an appear/disappear cycle.
        activeStorageEdit = nil
        activeRemovableEdit = nil
    }

    private let fileMonitor = AttachmentFileMonitor()
    /// Identifies the current file-monitor observation cycle.
    ///
    /// A new token is minted each `viewDidAppear`; a re-arming callback from an
    /// older cycle (which `hasDisappeared` alone can't cancel —
    /// `withObservationTracking` has no unregister) bails when its token no
    /// longer matches, so stale chains can't accumulate.
    private var fileMonitorObservationToken: UUID?

    private let reorderSheetPresenter = SheetPresenter()
    private let attachmentInfoPresenter = PopoverPresenter()
    private lazy var storageDiskCoordinator = DiskSizePopoverCoordinator(
        headline: "Create New Disk",
        caption:
            "Creates an ASIF sparse disk image inside the VM bundle. Physical size grows as data is written.",
        onConfirm: { [weak self] sizeInGB in
            guard let self else { return }
            self.viewModel.createStorageDisk(for: self.instance, sizeInGB: sizeInGB)
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
    /// Live storage row views keyed by disk id, so the context-menu "Rename"
    /// item can start inline editing on the right row.
    private var storageRowsByID: [UUID: AttachmentRowView] = [:]
    /// The disk being renamed or noted inline, or `nil`.
    ///
    /// While set, `refreshStorageList` skips its rebuild so an async refresh
    /// landing mid-edit can't destroy the editing field.
    private var activeStorageEdit: UUID?

    // Removable Media
    private var removableListStack = NSStackView()
    private var createRemovableButton: NSButton?
    /// Live removable-media row views keyed by item id.
    private var removableRowsByID: [UUID: AttachmentRowView] = [:]
    /// The removable medium being renamed or noted inline, or `nil`;
    /// suppresses `refreshRemovableList` mid-edit.
    private var activeRemovableEdit: UUID?

    private var renderedStorageRows: [VMSettingsRenderedRow]?
    private var renderedRemovableRows: [VMSettingsRenderedRow]?
    // MARK: - Read accessors (materialize defaults)

    private var currentStorageDisks: [StorageDisk] {
        attachmentStorageDisks(for: instance)
    }

    /// The storage disks list to render for `instance`.
    ///
    /// Takes the instance explicitly (rather than reading `self.instance`) so a
    /// caller holding a pinned instance — a rename/notes commit deferred across
    /// a runloop turn, which can land after `reconfigure` rebinds `self.instance`
    /// to a different VM — resolves against the VM it actually started with.
    private func attachmentStorageDisks(for instance: VMInstance) -> [StorageDisk] {
        instance.displayedStorageDisks
    }

    private var currentRemovableMedia: [RemovableMediaItem] {
        instance.configuration.removableMedia ?? []
    }

    private func writeStorageDisks(_ disks: [StorageDisk]) {
        viewModel.updateConfiguration(of: instance) { $0.storageDisks = disks.isEmpty ? nil : disks }
    }

    private func writeRemovableMedia(_ items: [RemovableMediaItem]) {
        viewModel.updateConfiguration(of: instance) { $0.removableMedia = items.isEmpty ? nil : items }
    }

    /// Seeds the file monitor with the current instance's attachment paths.
    private func startInstanceSideEffects() {
        let refs = externalAttachmentRefs(for: instance.configuration)
        Task { await fileMonitor.setPaths(refs) }
    }

    /// Re-arming `withObservationTracking` on `fileMonitor.existsByPath`, so the
    /// missing-file affordance on attachment rows updates live.
    ///
    /// The `hasDisappeared` guard breaks the chain on dismissal, and the `token`
    /// makes a callback from a prior appear cycle bail.
    private func observeFileMonitor(token: UUID) {
        if context.isDismissed || fileMonitorObservationToken != token { return }
        withObservationTracking { [fileMonitor] in
            _ = fileMonitor.existsByPath
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.context.isDismissed, self.fileMonitorObservationToken == token
                else { return }
                self.refreshStorageList()
                self.refreshRemovableList()
                self.observeFileMonitor(token: token)
            }
        }
    }

    // MARK: Storage Disks

    private func buildStorageSection() -> NSView {
        storageListStack = makeGroupedFormListStack()
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
            lockRegistry.makeHeader("Storage Disks", lockable: true, paragraphs: paragraphs), card,
        ])
    }

    // MARK: Removable Media

    private func buildRemovableMediaSection() -> NSView {
        removableListStack = makeGroupedFormListStack()
        let attach = makeGroupedFormPushButton("Attach Disk…", target: self, action: #selector(attachRemovableTapped))
        let create = makeGroupedFormPushButton(
            "Create New Disk…", target: self, action: #selector(createRemovableTapped))
        createRemovableButton = create
        // Not lockable — removable media is hot-pluggable.
        let buttonRow = makeGroupedFormButtonRow([attach, create])
        let card = makeGroupedFormCard(rows: [removableListStack, buttonRow])

        let firstParagraph: InfoPopoverParagraph =
            instance.configuration.guestOS == .linux
            ? .body(
                "Appears as a USB Mass Storage device (typically `/dev/sda` or similar). Most desktop distros auto-mount; headless installs need an explicit `mount`."
            )
            : .body("Appears as a removable USB drive in Finder; auto-mounts.")
        return makeGroupedFormSection([
            lockRegistry.makeHeader(
                "Removable Media",
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
            let isMissing = !disk.isInternal && !fileMonitor.exists(disk.path)
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
                controlsEnabled: !isReadOnly)
        }
        refreshAttachmentList(
            models: models, listStack: storageListStack, kind: .storage,
            rowsByID: \.storageRowsByID, rendered: \.renderedStorageRows,
            activeEdit: \.activeStorageEdit,
            readOnlySelector: #selector(storageReadOnlyToggled), emptyMessage: nil
        ) { [weak self] field, model in
            guard let self,
                let disk = self.currentStorageDisks.first(where: { $0.id == model.id })
            else { return }
            populateDiskSubtitle(
                field, for: disk, bundleLayout: self.instance.bundleLayout,
                isMissing: model.isMissing)
        }
    }

    private func refreshRemovableList() {
        let items = currentRemovableMedia
        let models = items.map { item -> VMSettingsRenderedRow in
            let isMissing = !fileMonitor.exists(item.path)
            return VMSettingsRenderedRow(
                id: item.id,
                iconSystemName: "opticaldisc",
                title: item.label,
                notes: item.notes,
                // Removable media is always external and hot-pluggable, so
                // controls stay enabled even while the VM runs.
                subtitle: item.path,
                isMissing: isMissing,
                missingPath: isMissing ? item.path : nil,
                readOnly: item.readOnly,
                controlsEnabled: true)
        }
        refreshAttachmentList(
            models: models, listStack: removableListStack, kind: .removable,
            rowsByID: \.removableRowsByID, rendered: \.renderedRemovableRows,
            activeEdit: \.activeRemovableEdit,
            readOnlySelector: #selector(removableReadOnlyToggled),
            emptyMessage: "No removable media attached"
        ) { [weak self] field, model in
            guard let self,
                let item = self.currentRemovableMedia.first(where: { $0.id == model.id })
            else { return }
            populateDiskSubtitle(
                field, for: item, bundleLayout: self.instance.bundleLayout,
                isMissing: model.isMissing)
        }
    }

    private func refresh(_ kind: AttachmentKind) {
        switch kind {
        case .storage: refreshStorageList()
        case .removable: refreshRemovableList()
        }
    }

    /// Shared rebuild/in-place-update engine for both attachment lists.
    ///
    /// A structural change (rows added, removed, or reordered) rebuilds the
    /// stack; anything else updates the affected rows in place. Only the
    /// structural path tears down an in-progress editing field, so only it is
    /// skipped while a row is being renamed. The live size is re-read on *every*
    /// in-place pass, so an out-of-band resize is reflected.
    private func refreshAttachmentList(
        models: [VMSettingsRenderedRow],
        listStack: NSStackView,
        kind: AttachmentKind,
        rowsByID rowsKP: ReferenceWritableKeyPath<VMSettingsStoragePanelViewController, [UUID: AttachmentRowView]>,
        rendered renderedKP: ReferenceWritableKeyPath<VMSettingsStoragePanelViewController, [VMSettingsRenderedRow]?>,
        activeEdit activeKP: ReferenceWritableKeyPath<VMSettingsStoragePanelViewController, UUID?>,
        readOnlySelector: Selector,
        emptyMessage: String?,
        populate: @escaping (NSTextField, VMSettingsRenderedRow) -> Void
    ) {
        let previousRows = self[keyPath: renderedKP]
        let structural = previousRows?.map(\.id) != models.map(\.id)

        if structural {
            // A rebuild would destroy an in-progress editing field, so defer it
            // until the edit ends (the cancel/commit handler re-runs the refresh).
            if self[keyPath: activeKP] != nil { return }
            self[keyPath: renderedKP] = models
            clearGroupedFormStack(listStack)
            self[keyPath: rowsKP].removeAll(keepingCapacity: true)
            guard !models.isEmpty else {
                if let emptyMessage {
                    addGroupedFormFullWidth(makeGroupedFormSecondaryLabel(emptyMessage), to: listStack)
                }
                return
            }
            for model in models {
                let row = makeAttachmentRow(
                    model: model, kind: kind, readOnlySelector: readOnlySelector,
                    activeEdit: activeKP)
                self[keyPath: rowsKP][model.id] = row
                addGroupedFormFullWidth(row, to: listStack)
                // Freshly built rows start with an empty subtitle — read once.
                populate(row.subtitleField, model)
            }
            return
        }

        self[keyPath: renderedKP] = models
        let previousByID = Dictionary(
            (previousRows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for model in models {
            guard let row = self[keyPath: rowsKP][model.id] else { continue }
            if previousByID[model.id] != model {
                row.update(
                    title: model.title, notes: model.notes, iconSystemName: model.iconSystemName,
                    missingPath: model.missingPath, readOnly: model.readOnly,
                    controlsEnabled: model.controlsEnabled)
            }
            populate(row.subtitleField, model)
        }
    }

    /// Builds one attachment row, wiring its icon Get Info, rename/notes
    /// closures, and context menu; the per-list differences arrive via `kind`,
    /// `readOnlySelector`, and the active-edit key path.
    private func makeAttachmentRow(
        model: VMSettingsRenderedRow,
        kind: AttachmentKind,
        readOnlySelector: Selector,
        activeEdit activeKP: ReferenceWritableKeyPath<VMSettingsStoragePanelViewController, UUID?>
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
        row.onEditBegan = { [weak self] id in self?[keyPath: activeKP] = id }
        row.onRenameCommitted = { [weak self] _, newLabel in
            self?.commitAttachmentRename(ref, newLabel: newLabel)
        }
        row.onRenameCancelled = { [weak self] _ in
            self?[keyPath: activeKP] = nil
            self?.refresh(kind)
        }
        row.onNotesCommitted = { [weak self] _, notes in
            self?.commitAttachmentNotes(ref, notes: notes)
        }
        row.onNotesCancelled = { [weak self] _ in
            self?[keyPath: activeKP] = nil
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
                if let disk = self.attachmentStorageDisks(for: instance).first(where: { $0.id == ref.id }) {
                    self.viewModel.renameStorageDisk(disk, newLabel: newLabel, on: instance)
                }
            case .removable:
                if let item = (instance.configuration.removableMedia ?? [])
                    .first(where: { $0.id == ref.id })
                {
                    self.viewModel.renameRemovableMedia(item, newLabel: newLabel, on: instance)
                }
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
                if let disk = self.attachmentStorageDisks(for: instance).first(where: { $0.id == ref.id }) {
                    self.viewModel.setStorageDiskNotes(disk, notes: notes, on: instance)
                }
            case .removable:
                if let item = (instance.configuration.removableMedia ?? [])
                    .first(where: { $0.id == ref.id })
                {
                    self.viewModel.setRemovableMediaNotes(item, notes: notes, on: instance)
                }
            }
            self.refresh(ref.kind)
        }
    }

    private func clearActiveEdit(_ kind: AttachmentKind) {
        switch kind {
        case .storage: activeStorageEdit = nil
        case .removable: activeRemovableEdit = nil
        }
    }

    /// Whether either attachment list has an inline edit open — Rename and Edit
    /// Notes on a row have to wait for it, same hazard
    /// ``SnapshotSectionView/makeRowMenu(for:canRevert:canDelete:isBaseline:)``
    /// guards against.
    private func hasActiveEdit(_ kind: AttachmentKind) -> Bool {
        switch kind {
        case .storage: return activeStorageEdit != nil
        case .removable: return activeRemovableEdit != nil
        }
    }

    // MARK: Storage

    @objc private func attachStorageTapped() {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM", allowsMultipleSelection: true)
        guard !urls.isEmpty else { return }
        var current = currentStorageDisks
        let existing = Set(current.map(\.path))
        for url in urls {
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            guard !existing.contains(path) else { continue }
            current.append(StorageDisk(path: path, bookmark: bookmark))
        }
        writeStorageDisks(current)
    }

    @objc private func createStorageTapped() {
        storageDiskCoordinator.show(from: createStorageButton)
    }

    @objc private func editBootOrderTapped() {
        guard let window = view.window else { return }
        let sheet = StorageDiskReorderSheetContentViewController(
            disks: currentStorageDisks, instance: instance, fileMonitor: fileMonitor)
        sheet.delegate = self
        reorderSheetPresenter.show(content: sheet, in: window)
    }

    @objc private func storageReadOnlyToggled(_ sender: NSSwitch) {
        guard let id = attachmentUUID(from: sender) else { return }
        setStorageReadOnly(sender.state == .on, forDiskID: id)
    }

    private func setStorageReadOnly(_ readOnly: Bool, forDiskID id: UUID) {
        var disks = currentStorageDisks
        guard let index = disks.firstIndex(where: { $0.id == id }) else { return }
        disks[index].readOnly = readOnly
        writeStorageDisks(disks)
    }

    private func presentStorageDeleteConfirmation(forDiskID id: UUID) {
        guard let window = view.window,
            let disk = currentStorageDisks.first(where: { $0.id == id })
        else { return }
        // Internal (bundle-relative) disks are per-VM, so they're never shared;
        // only resolve sharing for external disks.
        let shared = disk.isInternal ? [] : viewModel.sharingVMNames(forPath: disk.path, excluding: instance)
        let prompt = Self.attachmentDeletePrompt(
            label: disk.label,
            isInternal: disk.isInternal,
            isMainDisk: viewModel.isMainDisk(disk, of: instance),
            isGuestAgent: false,
            sharedVMNames: shared)
        presentSheetAlert(
            makeDeleteAlert(prompt: prompt) { [weak self] trashFile in
                guard let self else { return }
                _ = self.viewModel.removeStorageDisk(disk, from: self.instance, trashFile: trashFile)
            },
            in: window)
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
        /// Rename / Read Only / Remove gating: storage follows the running-VM
        /// read-only lock; removable media is hot-pluggable, so always editable.
        let editable: Bool
    }

    private func attachmentInfo(_ ref: AttachmentRef) -> AttachmentInfo? {
        switch ref.kind {
        case .storage:
            guard let disk = currentStorageDisks.first(where: { $0.id == ref.id }) else { return nil }
            return AttachmentInfo(
                id: disk.id, label: disk.label, path: disk.path, isInternal: disk.isInternal,
                readOnly: disk.readOnly,
                busText: disk.kind == .usbMassStorage ? "USB mass storage" : "Virtio block",
                notes: disk.notes, editable: !isReadOnly)
        case .removable:
            guard let item = currentRemovableMedia.first(where: { $0.id == ref.id }) else { return nil }
            return AttachmentInfo(
                id: item.id, label: item.label, path: item.path, isInternal: false,
                readOnly: item.readOnly, busText: "USB mass storage", notes: item.notes,
                editable: true)
        }
    }

    private func attachmentRow(_ ref: AttachmentRef) -> AttachmentRowView? {
        switch ref.kind {
        case .storage: return storageRowsByID[ref.id]
        case .removable: return removableRowsByID[ref.id]
        }
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
        // The only route to a note on a row that has none: with nothing on
        // screen to click, the row alone offers no way in.
        let editNotes = attachmentMenuItem("Edit Notes", #selector(menuAttachmentEditNotes(_:)), ref)
        editNotes.isEnabled = info.editable && noEditInFlight
        menu.addItem(editNotes)
        menu.addItem(attachmentMenuItem("Get Info", #selector(menuAttachmentGetInfo(_:)), ref))

        menu.addItem(.separator())

        let showInFinder = attachmentMenuItem(
            "Show in Finder", #selector(menuAttachmentShowInFinder(_:)), ref)
        // Nothing to reveal when an external file is missing (in-bundle always exists).
        showInFinder.isEnabled = info.isInternal || fileMonitor.exists(info.path)
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
        let remove = attachmentMenuItem("Remove…", #selector(menuAttachmentRemove(_:)), ref)
        remove.isEnabled = info.editable
        menu.addItem(remove)

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

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
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

    /// Decides the per-row delete confirmation (title, message, offered actions)
    /// purely from the item's nature.
    ///
    /// The Guest Agent installer and files shared with another VM can only be
    /// detached, never trashed.
    static func attachmentDeletePrompt(
        label: String,
        isInternal: Bool,
        isMainDisk: Bool,
        isGuestAgent: Bool,
        sharedVMNames: [String]
    ) -> AttachmentDeletePrompt {
        let title = "Remove \u{201C}\(label)\u{201D}?"

        if isGuestAgent {
            return AttachmentDeletePrompt(
                title: title,
                message:
                    "Detaches the Guest Agent installer from this VM. It's part of Kernova, so the file isn't deleted.",
                actions: [.removeFromVM])
        }

        if !sharedVMNames.isEmpty {
            return AttachmentDeletePrompt(
                title: title,
                message:
                    "Detaches it from this VM. Its file is kept — still used by \(DataFormatters.quotedList(sharedVMNames)).",
                actions: [.removeFromVM])
        }

        if isInternal {
            let base = "Moves the disk image to the Trash. You can restore it with Finder's Put Back."
            return AttachmentDeletePrompt(
                title: title,
                message: isMainDisk
                    ? "\(base) This is the VM's startup disk — it won't boot without it."
                    : base,
                actions: [.moveToTrash])
        }

        return AttachmentDeletePrompt(
            title: title,
            message:
                "Move to Trash sends the file to the Trash. Remove from VM detaches it but keeps the file.",
            actions: [.moveToTrash, .removeFromVM])
    }

    // MARK: Removable

    @objc private func attachRemovableTapped() {
        let urls = NSOpenPanel.browseDiskImages(
            message: "Select disk images to attach to the VM", allowsMultipleSelection: true)
        guard !urls.isEmpty else { return }
        var current = currentRemovableMedia
        let existing = Set(current.map(\.path))
        for url in urls {
            let (path, bookmark) = SecurityScopedBookmark.capture(url)
            guard !existing.contains(path) else { continue }
            current.append(RemovableMediaItem(path: path, readOnly: true, bookmark: bookmark))
        }
        writeRemovableMedia(current)
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
        var items = currentRemovableMedia
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].readOnly = readOnly
        writeRemovableMedia(items)
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
        guard let item = currentRemovableMedia.first(where: { $0.id == id }) else { return }
        _ = viewModel.removeRemovableMedia(item, from: instance, trashFile: false)
    }

    private func presentRemovableDeleteConfirmation(forItemID id: UUID) {
        guard let window = view.window,
            let item = currentRemovableMedia.first(where: { $0.id == id })
        else { return }
        let isAgent = viewModel.isGuestAgentInstaller(item)
        let shared = isAgent ? [] : viewModel.sharingVMNames(forPath: item.path, excluding: instance)
        let prompt = Self.attachmentDeletePrompt(
            label: item.label,
            isInternal: false,
            isMainDisk: false,
            isGuestAgent: isAgent,
            sharedVMNames: shared)
        presentSheetAlert(
            makeDeleteAlert(prompt: prompt) { [weak self] trashFile in
                guard let self else { return }
                _ = self.viewModel.removeRemovableMedia(item, from: self.instance, trashFile: trashFile)
            },
            in: window)
    }

    private func presentRemovableSavePanel(sizeInGB: Int) {
        let panel = NSSavePanel()
        panel.title = "Save Removable Disk"
        panel.message = "Choose where to save the new removable disk image."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "\(instance.name) Removable Disk.asif"
        panel.allowedContentTypes = [.asif]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.viewModel.createRemovableMedia(for: self.instance, sizeInGB: sizeInGB, destinationURL: url)
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
        writeStorageDisks(disks)
    }

    func storageDiskReorderSheetDidDismiss(_ vc: StorageDiskReorderSheetContentViewController) {
        reorderSheetPresenter.close()
    }
}
