import AppKit

/// What a snapshot row's controls ask the settings pane to do.
@MainActor
protocol SnapshotSectionViewDelegate: AnyObject {
    func snapshotSectionRequestedTakeSnapshot(_ view: SnapshotSectionView)
    func snapshotSection(_ view: SnapshotSectionView, requestedRevertTo snapshot: VMSnapshot)
    func snapshotSection(_ view: SnapshotSectionView, requestedDeleteOf snapshot: VMSnapshot)
    func snapshotSection(
        _ view: SnapshotSectionView, renamed snapshot: VMSnapshot, to newName: String)
    func snapshotSection(
        _ view: SnapshotSectionView, setNotes notes: String, on snapshot: VMSnapshot)
    func snapshotSection(
        _ view: SnapshotSectionView, requestedInfoFor snapshot: VMSnapshot, from anchor: NSView)
}

/// The VM Settings pane's Snapshots section: header readout, one row per
/// snapshot newest-first, and the "Take Snapshot…" footer link.
///
/// Self-contained so the settings controller only builds it, hands it state,
/// and answers its delegate.
@MainActor
final class SnapshotSectionView: NSView {
    weak var delegate: SnapshotSectionViewDelegate?

    /// The snapshot whose name or note is being edited inline, or `nil`.
    var activeEdit: UUID? { list.activeEdit }

    /// The section's info affordance, exposed so a panel header can host it in
    /// place of the inner section header.
    let infoButton = InfoButtonView()

    private let readoutLabel = NSTextField(labelWithString: "")

    /// The header's size readout, exposed on the same terms as ``infoButton``.
    var sizeReadout: NSView { readoutLabel }
    private let listStack = NSStackView()
    private var takeSnapshotButton = NSButton()

    /// What the rows were last rendered under, so a cancelled edit can
    /// re-render without the settings pane feeding the state in again.
    private var gate = Gate(
        canTakeSnapshot: false, canRevert: false, canDelete: false, baselineID: nil)

    private struct Gate {
        let canTakeSnapshot: Bool
        let canRevert: Bool
        /// Whether the ••• menu's Delete is offered.
        let canDelete: Bool
        /// The VM's Ephemeral baseline, which the mode bars deleting.
        let baselineID: UUID?
    }

    /// The rows, keyed by snapshot id — so the ••• menu's "Rename" starts
    /// editing on the right row and the size read lands on the right subtitle —
    /// and the rebuild/in-place diff behind them.
    private lazy var list = VMSettingsKeyedListController<SnapshotRowModel, SnapshotRowView>(
        listStack: listStack, emptyMessage: "No snapshots",
        separator: { makeGroupedFormHairline() })

    /// The manifest the rows were last built from, so a delegate callback can
    /// name the snapshot a control belongs to.
    private var manifest = VMSnapshotManifest()

    /// Per-snapshot on-disk sizes, filled in by ``applySizes(_:)`` once the
    /// off-main read lands; a row with no entry yet shows its date alone.
    private var sizesByID: [UUID: UInt64] = [:]

    /// Whether the section draws its own header, or hands ``infoButton`` and
    /// ``sizeReadout`` to a panel header that states the category name instead.
    private let showsHeader: Bool

    init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
        super.init(frame: .zero)
        takeSnapshotButton = makeLinkButton(
            "Take Snapshot\u{2026}", target: self, action: #selector(takeSnapshotTapped))
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SnapshotSectionView does not support NSCoder")
    }

    // MARK: - Layout

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = Spacing.relaxed
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let footerSpacer = NSView()
        footerSpacer.translatesAutoresizingMaskIntoConstraints = false
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [takeSnapshotButton, footerSpacer])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = Spacing.standard

        configureChrome()
        var rows: [NSView] = []
        if showsHeader { rows.append(makeHeader()) }
        rows.append(makeGroupedFormCard(rows: [listStack, footer]))
        rows.append(
            makeGroupedFormCaption(
                "Reverting returns the VM to the state and settings it had when the snapshot was "
                    + "taken. Snapshots stay until you delete them. A snapshot\u{2019}s size counts "
                    + "the blocks it shares with the VM\u{2019}s disks, so the listed sizes overlap "
                    + "rather than add up."))

        let section = NSStackView(views: rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = Spacing.small
        section.translatesAutoresizingMaskIntoConstraints = false

        addSubview(section)
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in section.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
    }

    /// Configures the two header pieces a panel header can host instead: they
    /// are built whether or not this section draws a header of its own.
    private func configureChrome() {
        infoButton.configure(
            label: "Snapshots",
            paragraphs: [
                .body(
                    "A snapshot copies the disks inside the VM's bundle, and pairs them with the "
                        + "guest's memory when the VM is running or suspended. Taken while it is "
                        + "stopped, a snapshot holds the disks alone and reverting returns the VM "
                        + "powered off."
                ),
                .body(
                    "Disks attached from outside the bundle are not captured — reverting leaves them as they are."
                ),
                .body(
                    "Unlike Suspend, reverting keeps the snapshot, so the same restore point can be used again."
                ),
                .body(
                    "A new snapshot's copies share their blocks with the disks they were copied "
                        + "from, and keep sharing them until one side changes. Its listed size is "
                        + "what those files hold, which is space the VM \u{2014} and any other "
                        + "snapshot of the same disks \u{2014} is counted for too."
                ),
            ])

        readoutLabel.font = .preferredFont(forTextStyle: .caption1)
        readoutLabel.textColor = .secondaryLabelColor
        readoutLabel.isSelectable = false
        readoutLabel.toolTip =
            "The space the snapshots\u{2019} files hold. Their copies share blocks with the "
            + "VM\u{2019}s disks, so this overlaps with the VM rather than adding to it."
        readoutLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func makeHeader() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [
            makeGroupedFormSectionHeader("Snapshots"), infoButton, spacer, readoutLabel,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Spacing.small
        return header
    }

    // MARK: - State

    /// Renders `manifest`, rebuilding the rows only when what they show changed.
    ///
    /// `baselineID` names the VM's Ephemeral baseline, or is `nil` when the mode
    /// is off.
    func update(
        manifest: VMSnapshotManifest, canTakeSnapshot: Bool, canRevert: Bool, canDelete: Bool,
        baselineID: UUID?
    ) {
        self.manifest = manifest
        gate = Gate(
            canTakeSnapshot: canTakeSnapshot, canRevert: canRevert, canDelete: canDelete,
            baselineID: baselineID)
        takeSnapshotButton.isEnabled = canTakeSnapshot

        let models = manifest.ordered.map { snapshot in
            SnapshotRowModel(
                snapshot: snapshot, isCurrent: snapshot.id == manifest.currentID,
                isBaseline: snapshot.id == baselineID,
                canRevert: canRevert, canDelete: canDelete)
        }
        list.update(
            models,
            makeRow: { [self] model in makeRow(model) },
            applyRow: { [self] model, row in
                row.update(model, subtitle: subtitleText(for: model.snapshot))
            })
        refreshReadout()
    }

    /// Fills in the per-row and header size readouts.
    func applySizes(_ bytes: [UUID: UInt64]) {
        sizesByID = bytes
        for model in list.rendered ?? [] {
            guard let row = list.row(model.id) else { continue }
            row.subtitleField.stringValue = subtitleText(for: model.snapshot)
        }
        refreshReadout()
    }

    /// Begins inline editing of one snapshot's name.
    func beginRename(_ id: UUID) {
        list.row(id)?.titleView.beginRename()
    }

    /// Begins inline editing of one snapshot's note.
    func beginNotesEditing(_ id: UUID) {
        list.row(id)?.titleView.beginNotesEditing()
    }

    /// Drops any in-flight edit marker, so it can't pin the list in its
    /// suppressed (never-rebuilds) state across an appear/disappear cycle.
    func clearActiveEdit() {
        list.activeEdit = nil
    }

    /// Ends an inline edit and renders whatever arrived while it was open.
    ///
    /// A refresh landing mid-edit stores its manifest but skips the rebuild, so
    /// the list is stale by exactly what changed during the edit. The render is
    /// deferred because it can rebuild the rows, and it is reached from inside
    /// the editing field's own callback — that field comes off the stack first.
    private func endEdit() {
        list.activeEdit = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.update(
                manifest: self.manifest, canTakeSnapshot: self.gate.canTakeSnapshot,
                canRevert: self.gate.canRevert, canDelete: self.gate.canDelete,
                baselineID: self.gate.baselineID)
        }
    }

    /// The context menu for the row showing `id`, built from what that row
    /// currently renders; `nil` once the row is gone.
    func makeRowMenu(forRowWith id: UUID) -> NSMenu? {
        guard let snapshot = manifest.snapshot(id: id),
            let model = list.rendered?.first(where: { $0.id == id })
        else { return nil }
        return makeRowMenu(
            for: snapshot, canRevert: model.canRevert, canDelete: model.canDelete,
            isBaseline: model.isBaseline)
    }

    /// The context menu for one snapshot row — the same menu the ••• button
    /// pops and a right-click surfaces.
    ///
    /// Rename and Edit Notes only wait on `activeEdit`: their writes are
    /// metadata-only and land regardless of what the VM is doing. Delete
    /// follows `canDelete`, which is additionally barred on an Ephemeral
    /// baseline, which the VM needs back at every power-off.
    func makeRowMenu(
        for snapshot: VMSnapshot, canRevert: Bool, canDelete: Bool, isBaseline: Bool
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let rename = menuItem("Rename", #selector(menuRename(_:)), snapshot)
        rename.isEnabled = activeEdit == nil
        menu.addItem(rename)
        let editNotes = menuItem("Edit Notes", #selector(menuEditNotes(_:)), snapshot)
        editNotes.isEnabled = activeEdit == nil
        menu.addItem(editNotes)
        menu.addItem(menuItem("Get Info", #selector(menuGetInfo(_:)), snapshot))
        menu.addItem(.separator())
        let revert = menuItem("Revert", #selector(menuRevert(_:)), snapshot)
        revert.isEnabled = canRevert
        menu.addItem(revert)
        menu.addItem(.separator())
        // Always confirms, and destructively — so it carries the ellipsis.
        let delete = menuItem("Delete\u{2026}", #selector(menuDelete(_:)), snapshot)
        delete.isEnabled = canDelete && !isBaseline
        if canDelete && isBaseline {
            delete.toolTip =
                "This snapshot is the Ephemeral baseline. Turn off Ephemeral Mode to delete it."
        }
        menu.addItem(delete)
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, _ snapshot: VMSnapshot) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = snapshot.id.uuidString
        item.isEnabled = true
        return item
    }

    // MARK: - Rows

    private func makeRow(_ model: SnapshotRowModel) -> SnapshotRowView {
        let snapshotID = model.id
        let row = SnapshotRowView(
            snapshotID: snapshotID, target: self, revertAction: #selector(revertTapped(_:)),
            moreAction: #selector(moreTapped(_:)))

        row.icon.onActivate = { [weak self] anchor in
            guard let self, let snapshot = self.manifest.snapshot(id: snapshotID) else { return }
            self.delegate?.snapshotSection(self, requestedInfoFor: snapshot, from: anchor)
        }

        let title = row.titleView
        title.onEditBegan = { [weak self] id in self?.list.activeEdit = id }
        title.onRenameCommitted = { [weak self] id, newName in
            guard let self else { return }
            let snapshot = self.manifest.snapshot(id: id)
            self.endEdit()
            guard let snapshot else { return }
            self.delegate?.snapshotSection(self, renamed: snapshot, to: newName)
        }
        title.onRenameCancelled = { [weak self] _ in self?.endEdit() }
        title.onNotesCommitted = { [weak self] id, notes in
            guard let self else { return }
            let snapshot = self.manifest.snapshot(id: id)
            self.endEdit()
            guard let snapshot else { return }
            self.delegate?.snapshotSection(self, setNotes: notes, on: snapshot)
        }
        title.onNotesCancelled = { [weak self] _ in self?.endEdit() }
        // A note the row can't hold on one line is edited where it fits.
        title.onNotesOverflowActivated = { [weak self] id in
            guard let self, let snapshot = self.manifest.snapshot(id: id),
                let row = self.list.row(id)
            else { return }
            self.delegate?.snapshotSection(self, requestedInfoFor: snapshot, from: row.icon)
        }
        // Built at click time from the current model, not the one this row was
        // created with, so an enablement change that took the in-place path is
        // reflected.
        title.contextMenu = { [weak self] in self?.makeRowMenu(forRowWith: snapshotID) }
        return row
    }

    /// "date · Disks only · size on disk" — the middle part only for a snapshot
    /// that captured no memory, the last only once the size read lands.
    func subtitleText(for snapshot: VMSnapshot) -> String {
        var parts = [SnapshotDateFormat.string(from: snapshot.createdAt)]
        if snapshot.kind == .cold { parts.append("Disks only") }
        if let bytes = sizesByID[snapshot.id] {
            parts.append("\(DataFormatters.formatBytes(bytes)) on disk")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func refreshReadout() {
        let count = manifest.snapshots.count
        guard count > 0 else {
            readoutLabel.stringValue = ""
            readoutLabel.isHidden = true
            return
        }
        readoutLabel.isHidden = false
        let noun = count == 1 ? "snapshot" : "snapshots"
        let listed = manifest.snapshots.compactMap { sizesByID[$0.id] }
        guard listed.count == count else {
            readoutLabel.stringValue = "\(count) \(noun)"
            return
        }
        let total = listed.reduce(UInt64(0), &+)
        readoutLabel.stringValue =
            "\(count) \(noun) \u{00B7} \(DataFormatters.formatBytes(total)) on disk"
    }

    // MARK: - Actions

    @objc private func takeSnapshotTapped() {
        delegate?.snapshotSectionRequestedTakeSnapshot(self)
    }

    @objc private func revertTapped(_ sender: NSButton) {
        guard let snapshot = snapshot(from: sender.identifier?.rawValue) else { return }
        delegate?.snapshotSection(self, requestedRevertTo: snapshot)
    }

    @objc private func moreTapped(_ sender: NSButton) {
        guard let rawID = sender.identifier?.rawValue, let id = UUID(uuidString: rawID),
            let menu = makeRowMenu(forRowWith: id)
        else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let snapshot = snapshot(from: sender.representedObject as? String) else { return }
        beginRename(snapshot.id)
    }

    @objc private func menuEditNotes(_ sender: NSMenuItem) {
        guard let snapshot = snapshot(from: sender.representedObject as? String) else { return }
        beginNotesEditing(snapshot.id)
    }

    @objc private func menuGetInfo(_ sender: NSMenuItem) {
        guard let snapshot = snapshot(from: sender.representedObject as? String),
            let row = list.row(snapshot.id)
        else { return }
        delegate?.snapshotSection(self, requestedInfoFor: snapshot, from: row.icon)
    }

    @objc private func menuRevert(_ sender: NSMenuItem) {
        guard let snapshot = snapshot(from: sender.representedObject as? String) else { return }
        delegate?.snapshotSection(self, requestedRevertTo: snapshot)
    }

    @objc private func menuDelete(_ sender: NSMenuItem) {
        guard let snapshot = snapshot(from: sender.representedObject as? String) else { return }
        delegate?.snapshotSection(self, requestedDeleteOf: snapshot)
    }

    private func snapshot(from rawID: String?) -> VMSnapshot? {
        guard let rawID, let id = UUID(uuidString: rawID) else { return nil }
        return manifest.snapshot(id: id)
    }
}
