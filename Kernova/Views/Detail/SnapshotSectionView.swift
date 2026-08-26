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

    /// The snapshot being renamed inline, or `nil`.
    ///
    /// While set, ``update(manifest:canTakeSnapshot:canRevert:canModify:baselineID:)``
    /// skips its rebuild so a refresh landing mid-edit can't destroy the
    /// editing field.
    private(set) var activeRename: UUID?

    private let readoutLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private var takeSnapshotButton = NSButton()

    /// What the rows were last rendered under, so a cancelled rename can
    /// re-render without the settings pane feeding the state in again.
    private var gate = Gate(
        canTakeSnapshot: false, canRevert: false, canModify: false, baselineID: nil)

    private struct Gate {
        let canTakeSnapshot: Bool
        let canRevert: Bool
        /// Whether the list may be edited — the ••• menu's Rename and Delete.
        let canModify: Bool
        /// The VM's Ephemeral baseline, which the mode bars deleting.
        let baselineID: UUID?
    }

    /// Live row views keyed by snapshot id, so the ••• menu's "Rename" starts
    /// editing on the right row and the size read lands on the right subtitle.
    private var rowsByID: [UUID: Row] = [:]

    /// One row's views, retained so an in-place update needs no rebuild.
    private struct Row {
        let container: NSView
        let icon: AttachmentIconButton
        let title: InlineRenameTitleView
        let subtitle: NSTextField
        let markerLabel: NSTextField
        let revertButton: NSButton
    }

    /// Value snapshot of one row's rendered appearance, so a pass that changed
    /// nothing about it skips the rebuild.
    private struct RenderedRow: Equatable {
        let snapshot: VMSnapshot
        let isCurrent: Bool
        /// `true` for the snapshot Ephemeral Mode returns this VM to.
        let isBaseline: Bool
        let canRevert: Bool
        let canModify: Bool

        /// The row's trailing marker — the two roles read as one caption when a
        /// snapshot holds both, which is where an ephemeral VM rests.
        var markerText: String {
            switch (isBaseline, isCurrent) {
            case (true, true): "Baseline \u{00B7} Current"
            case (true, false): "Baseline"
            case (false, true): "Current"
            case (false, false): ""
            }
        }
    }
    private var renderedRows: [RenderedRow]?

    /// The manifest the rows were last built from, so a delegate callback can
    /// name the snapshot a control belongs to.
    private var manifest = VMSnapshotManifest()

    /// Per-snapshot on-disk sizes, filled in by ``applySizes(_:)`` once the
    /// off-main read lands; a row with no entry yet shows its date alone.
    private var sizesByID: [UUID: UInt64] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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

        let section = NSStackView(views: [
            makeHeader(),
            makeGroupedFormCard(rows: [listStack, footer]),
            makeGroupedFormCaption(
                "Reverting returns the VM to the state and settings it had when the snapshot was "
                    + "taken. Snapshots stay until you delete them. A snapshot\u{2019}s size counts "
                    + "the blocks it shares with the VM\u{2019}s disks, so the listed sizes overlap "
                    + "rather than add up."),
        ])
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

    private func makeHeader() -> NSView {
        let info = InfoButtonView()
        info.configure(
            label: "Snapshots",
            paragraphs: [
                .body(
                    "A snapshot copies the disks inside the VM's bundle, and pairs them with the "
                        + "guest's memory when the VM is running. Taken while it is stopped, a "
                        + "snapshot holds the disks alone and reverting returns the VM powered off."
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

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [
            makeGroupedFormSectionHeader("Snapshots"), info, spacer, readoutLabel,
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
        manifest: VMSnapshotManifest, canTakeSnapshot: Bool, canRevert: Bool, canModify: Bool,
        baselineID: UUID?
    ) {
        self.manifest = manifest
        gate = Gate(
            canTakeSnapshot: canTakeSnapshot, canRevert: canRevert, canModify: canModify,
            baselineID: baselineID)
        takeSnapshotButton.isEnabled = canTakeSnapshot

        let models = manifest.ordered.map { snapshot in
            RenderedRow(
                snapshot: snapshot, isCurrent: snapshot.id == manifest.currentID,
                isBaseline: snapshot.id == baselineID,
                canRevert: canRevert, canModify: canModify)
        }
        let structural = renderedRows?.map(\.snapshot.id) != models.map(\.snapshot.id)
        if structural {
            // A rebuild would destroy an in-progress editing field, so defer it
            // until the edit ends (the cancel/commit handler re-runs this).
            if activeRename != nil { return }
            renderedRows = models
            rebuildRows(models)
            refreshReadout()
            return
        }

        let previous = Dictionary(
            (renderedRows ?? []).map { ($0.snapshot.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        renderedRows = models
        for model in models {
            guard let row = rowsByID[model.snapshot.id], previous[model.snapshot.id] != model
            else { continue }
            apply(model, to: row)
        }
        refreshReadout()
    }

    /// Fills in the per-row and header size readouts.
    func applySizes(_ bytes: [UUID: UInt64]) {
        sizesByID = bytes
        for model in renderedRows ?? [] {
            guard let row = rowsByID[model.snapshot.id] else { continue }
            row.subtitle.stringValue = subtitleText(for: model.snapshot)
        }
        refreshReadout()
    }

    /// Begins inline editing of one snapshot's name.
    func beginRename(_ id: UUID) {
        rowsByID[id]?.title.beginRename()
    }

    /// Drops any in-flight rename marker, so it can't pin the list in its
    /// suppressed (never-rebuilds) state across an appear/disappear cycle.
    func clearActiveRename() {
        activeRename = nil
    }

    /// Ends a rename and renders whatever arrived while it was open.
    ///
    /// A refresh landing mid-edit stores its manifest but skips the rebuild, so
    /// the list is stale by exactly what changed during the edit. The render is
    /// deferred because it can rebuild the rows, and it is reached from inside
    /// the editing field's own callback — that field comes off the stack first.
    private func endRename() {
        activeRename = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.update(
                manifest: self.manifest, canTakeSnapshot: self.gate.canTakeSnapshot,
                canRevert: self.gate.canRevert, canModify: self.gate.canModify,
                baselineID: self.gate.baselineID)
        }
    }

    /// The context menu for the row showing `id`, built from what that row
    /// currently renders; `nil` once the row is gone.
    func makeRowMenu(forRowWith id: UUID) -> NSMenu? {
        guard let snapshot = manifest.snapshot(id: id),
            let model = renderedRows?.first(where: { $0.snapshot.id == id })
        else { return nil }
        return makeRowMenu(
            for: snapshot, canRevert: model.canRevert, canModify: model.canModify,
            isBaseline: model.isBaseline)
    }

    /// The context menu for one snapshot row — the same menu the ••• button
    /// pops and a right-click surfaces.
    ///
    /// Rename and Delete follow `canModify`: both write the manifest a revert
    /// is reading, and the serialization behind them rejects rather than
    /// queues, so an enabled item during an unsettled operation would only
    /// produce an error alert. Delete is additionally barred on an Ephemeral
    /// baseline, which the VM needs back at every power-off.
    func makeRowMenu(
        for snapshot: VMSnapshot, canRevert: Bool, canModify: Bool, isBaseline: Bool
    ) -> NSMenu {
        let canDelete = canModify && !isBaseline
        let menu = NSMenu()
        menu.autoenablesItems = false

        let rename = menuItem("Rename", #selector(menuRename(_:)), snapshot)
        rename.isEnabled = canModify && activeRename == nil
        menu.addItem(rename)
        menu.addItem(menuItem("Get Info", #selector(menuGetInfo(_:)), snapshot))
        menu.addItem(.separator())
        let revert = menuItem("Revert", #selector(menuRevert(_:)), snapshot)
        revert.isEnabled = canRevert
        menu.addItem(revert)
        menu.addItem(.separator())
        // Always confirms, and destructively — so it carries the ellipsis.
        let delete = menuItem("Delete\u{2026}", #selector(menuDelete(_:)), snapshot)
        delete.isEnabled = canDelete
        if canModify && !canDelete {
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

    private func rebuildRows(_ models: [RenderedRow]) {
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowsByID.removeAll(keepingCapacity: true)

        guard !models.isEmpty else {
            let empty = NSTextField(labelWithString: "No snapshots")
            empty.textColor = .secondaryLabelColor
            empty.isSelectable = false
            addFullWidth(empty)
            return
        }

        for (index, model) in models.enumerated() {
            if index > 0 { addFullWidth(makeGroupedFormHairline()) }
            let row = makeRow(model)
            rowsByID[model.snapshot.id] = row
            addFullWidth(row.container)
        }
    }

    private func addFullWidth(_ view: NSView) {
        listStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    private func makeRow(_ model: RenderedRow) -> Row {
        let snapshotID = model.snapshot.id

        let icon = AttachmentIconButton()
        icon.configure(systemName: "clock.arrow.circlepath", missingPath: nil)
        icon.onActivate = { [weak self] anchor in
            guard let self, let snapshot = self.manifest.snapshot(id: snapshotID) else { return }
            self.delegate?.snapshotSection(self, requestedInfoFor: snapshot, from: anchor)
        }

        let title = InlineRenameTitleView(
            itemID: snapshotID, title: model.snapshot.name, controlsEnabled: model.canModify)
        title.onRenameBegan = { [weak self] id in self?.activeRename = id }
        title.onRenameCommitted = { [weak self] id, newName in
            guard let self else { return }
            let snapshot = self.manifest.snapshot(id: id)
            self.endRename()
            guard let snapshot else { return }
            self.delegate?.snapshotSection(self, renamed: snapshot, to: newName)
        }
        title.onRenameCancelled = { [weak self] _ in self?.endRename() }
        // Built at click time from the current model, not the one this row was
        // created with, so an enablement change that took the in-place path is
        // reflected.
        title.contextMenu = { [weak self] in self?.makeRowMenu(forRowWith: snapshotID) }

        let subtitle = NSTextField(labelWithString: subtitleText(for: model.snapshot))
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.isSelectable = false
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
            subtitle.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
        ])

        let markerLabel = NSTextField(labelWithString: model.markerText)
        markerLabel.font = .preferredFont(forTextStyle: .caption1)
        markerLabel.textColor = .secondaryLabelColor
        markerLabel.isSelectable = false

        let revert = makeLinkButton("Revert", target: self, action: #selector(revertTapped(_:)))
        revert.font = Typography.body
        revert.identifier = NSUserInterfaceItemIdentifier(snapshotID.uuidString)

        let menuButton = NSButton()
        menuButton.image = .systemSymbol("ellipsis.circle", accessibilityDescription: "More")
        menuButton.imagePosition = .imageOnly
        menuButton.isBordered = false
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.toolTip = "More"
        menuButton.identifier = NSUserInterfaceItemIdentifier(snapshotID.uuidString)
        menuButton.target = self
        menuButton.action = #selector(moreTapped(_:))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for accessory in [icon, markerLabel, revert, menuButton] as [NSView] {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let container = NSStackView(views: [
            icon, textStack, spacer, markerLabel, revert, menuButton,
        ])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.distribution = .fill
        container.spacing = Spacing.standard
        container.translatesAutoresizingMaskIntoConstraints = false

        let row = Row(
            container: container, icon: icon, title: title, subtitle: subtitle,
            markerLabel: markerLabel, revertButton: revert)
        apply(model, to: row)
        return row
    }

    private func apply(_ model: RenderedRow, to row: Row) {
        row.title.update(title: model.snapshot.name, controlsEnabled: model.canModify)
        row.subtitle.stringValue = subtitleText(for: model.snapshot)
        row.markerLabel.stringValue = model.markerText
        row.markerLabel.toolTip = Self.markerToolTip(for: model)
        row.markerLabel.isHidden = model.markerText.isEmpty
        row.revertButton.isEnabled = model.canRevert
    }

    /// What each marker role means, so the caption doesn't have to spell it out.
    private static func markerToolTip(for model: RenderedRow) -> String? {
        let current = "The state this VM was last taken from or reverted to"
        let baseline = "The snapshot this VM returns to at every shutdown"
        switch (model.isBaseline, model.isCurrent) {
        case (true, true): return "\(baseline). \(current)."
        case (true, false): return baseline
        case (false, true): return current
        case (false, false): return nil
        }
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

    @objc private func menuGetInfo(_ sender: NSMenuItem) {
        guard let snapshot = snapshot(from: sender.representedObject as? String),
            let row = rowsByID[snapshot.id]
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
