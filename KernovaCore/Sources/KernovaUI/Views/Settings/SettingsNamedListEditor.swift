import AppKit
import KernovaCore
import KernovaLogging

/// What a Settings pane listing the library's named items — its networks, its
/// tags — supplies to the ``SettingsNamedListEditor`` that shows them.
@MainActor
protocol SettingsNamedListSource: AnyObject {
    /// The items, read afresh, by identifier in list order; `nil` while the
    /// file listing them can't be read.
    func listedIDs() -> [UUID]?
    /// What the pane says in place of the list while it can't be read.
    var unreadableText: String { get }
    /// Opens the config file check, from the notice that stands in for a
    /// list that can't be read.
    func showConfigCheck()
    /// The name of the item `id` identifies, which its name cell shows and
    /// takes a rename in.
    func name(of id: UUID) -> String
    /// What the text column `column` shows of the item `id` identifies.
    func text(for column: NSUserInterfaceItemIdentifier, of id: UUID) -> String
    /// A control the column `column` shows for the item `id` identifies in
    /// place of text, `nil` for a text column.
    func control(for column: NSUserInterfaceItemIdentifier, of id: UUID) -> NSView?
    /// Reads every value the list shows, so an observation of it wakes on
    /// any change from any window or the CLI.
    func readListedValues()
    /// Renames the item `id` identifies.
    func rename(_ id: UUID, to name: String) throws
    /// Whether the list offers a new item.
    var canCreate: Bool { get }
    /// Asks for a new item, on the pane's window.
    func presentCreate()
    /// The question deleting the item `id` identifies asks; `delete` runs on
    /// its confirmation.
    func deleteConfirmation(for id: UUID, delete: @escaping () -> Void) -> AlertConfiguration?
    /// Deletes the item `id` identifies.
    func delete(_ id: UUID) throws
}

/// A Settings pane's list of the library's named items: a table whose names
/// are renamed in place, a +/− control that creates through the source and
/// deletes after its confirmation, and an observation loop, live while the
/// pane is on screen, that repaints the list on any change.
///
/// A refusal is shown as a sheet on the Settings window; a refused name opens
/// the rename again, holding it, once the sheet is dismissed. A change from
/// elsewhere arriving while a name is being edited repaints once the edit
/// ends, since a reload would end the edit; the pane's own changes end the
/// edit, committing it, before they run. While the list can't be read, a
/// notice pointing to the config file check stands in for it, and the
/// control offers nothing.
@MainActor
final class SettingsNamedListEditor: NSObject {
    /// One table column.
    struct Column {
        let id: NSUserInterfaceItemIdentifier
        let title: String
        let width: CGFloat
    }

    private let logger: KernovaLogger
    /// What one item is called in the control's tooltips: "Network", "Tag".
    private let noun: String
    private let nameColumn: NSUserInterfaceItemIdentifier
    private weak var source: (any SettingsNamedListSource)?

    let tableView = SettingsNamedListTableView()
    private let scrollView = NSScrollView()
    private let unreadableNotice = NSStackView()
    private let unreadableLabel = NSTextField(wrappingLabelWithString: "")
    private let addRemoveControl = NSSegmentedControl()
    private static let addSegment = 0
    private static let removeSegment = 1

    /// The items the table shows, by identifier.
    private(set) var ids: [UUID] = []
    /// Whether the last read found the list unreadable, which the pane shows
    /// in place of the table.
    private(set) var isUnreadable = false
    /// The name cell whose rename is open, from the moment it opens — before
    /// anything is typed.
    private var openRename: SettingsNamedListNameCellView? {
        let column = tableView.column(withIdentifier: nameColumn)
        guard column >= 0 else { return nil }
        return (0..<tableView.numberOfRows).lazy
            .compactMap { self.tableView.view(atColumn: column, row: $0, makeIfNecessary: false) }
            .compactMap { $0 as? SettingsNamedListNameCellView }
            .first { $0.isRenaming }
    }
    private var observation: ObservationLoop?

    /// A slow second click's rename waits out the double-click interval
    /// through `renameDeferral`.
    init(
        noun: String, columns: [Column], nameColumn: NSUserInterfaceItemIdentifier, logger: KernovaLogger,
        source: any SettingsNamedListSource,
        renameDeferral: @escaping InPlaceRenameClicks<UUID>.Deferral = afterDoubleClickInterval
    ) {
        self.noun = noun
        self.nameColumn = nameColumn
        self.logger = logger
        self.source = source
        super.init()
        configureTable(columns, renameDeferral: renameDeferral)
    }

    // MARK: - View

    /// The pane's view: `header`, `caption`, the list and its control.
    func makePaneView(header: String, caption: String) -> NSView {
        let header = makeGroupedFormSectionHeader(header)
        let caption = makeGroupedFormContentText(caption)

        configureUnreadableNotice()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addRemoveControl.segmentCount = 2
        addRemoveControl.segmentStyle = .smallSquare
        addRemoveControl.trackingMode = .momentary
        addRemoveControl.setImage(symbol(NSImage.addTemplateName), forSegment: Self.addSegment)
        addRemoveControl.setImage(symbol(NSImage.removeTemplateName), forSegment: Self.removeSegment)
        addRemoveControl.setToolTip("New \(noun)", forSegment: Self.addSegment)
        addRemoveControl.setToolTip("Delete \(noun)", forSegment: Self.removeSegment)
        addRemoveControl.target = self
        addRemoveControl.action = #selector(addRemoveClicked)

        let content = NSStackView(views: [header, caption, scrollView, unreadableNotice, addRemoveControl])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Spacing.small
        content.setCustomSpacing(Spacing.none, after: scrollView)
        content.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(content)
        let pad = Spacing.large
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            root.widthAnchor.constraint(equalToConstant: SettingsPaneMetrics.width),
            caption.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 180),
            unreadableNotice.widthAnchor.constraint(equalTo: content.widthAnchor),
            unreadableNotice.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
        return SettingsPaneRootView(content: root)
    }

    /// What the pane shows in place of the table while the list can't be
    /// read.
    private func configureUnreadableNotice() {
        unreadableLabel.font = Typography.body
        unreadableLabel.textColor = .secondaryLabelColor
        unreadableLabel.alignment = .center
        let check = NSButton(
            title: "Check Config Files\u{2026}", target: self, action: #selector(checkConfigFiles))
        check.bezelStyle = .push
        unreadableNotice.setViews([unreadableLabel, check], in: .center)
        unreadableNotice.orientation = .vertical
        unreadableNotice.alignment = .centerX
        unreadableNotice.spacing = Spacing.standard
        unreadableNotice.translatesAutoresizingMaskIntoConstraints = false
        unreadableNotice.isHidden = true
    }

    private func configureTable(_ columns: [Column], renameDeferral: @escaping InPlaceRenameClicks<UUID>.Deferral) {
        for spec in columns {
            let column = NSTableColumn(identifier: spec.id)
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .fullWidth
        tableView.dataSource = self
        tableView.delegate = self
        let clicks = InPlaceRenameClicks<UUID>(
            table: tableView, doubleClickBegins: true, deferral: renameDeferral,
            item: { [weak self] row in
                guard let self, ids.indices.contains(row) else { return nil }
                return ids[row]
            },
            row: { [weak self] id in self?.ids.firstIndex(of: id) },
            isOverName: { [weak self] point, _ in
                guard let self else { return false }
                return tableView.column(at: point) == tableView.column(withIdentifier: nameColumn)
            })
        clicks.begin = { [weak self] row in
            guard let self, ids.indices.contains(row) else { return }
            beginRename(of: ids[row])
        }
        tableView.renameClicks = clicks
    }

    // MARK: - Observation

    /// Repaints the list whenever what it shows changes, until
    /// ``stopObserving()``.
    func startObserving() {
        observation?.cancel()
        observation = observeRecurring(
            track: { [weak self] in self?.source?.readListedValues() },
            apply: { [weak self] in self?.reload() })
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        tableView.renameClicks?.cancel()
    }

    // MARK: - List

    /// Re-reads the items and repaints the list, keeping the selection on the
    /// item it was on.
    func reload() {
        // A reload would end the edit; the edit's end repaints instead.
        guard openRename == nil else { return }
        repaint()
    }

    private func repaint() {
        guard let source else { return }
        let selected = selectedID
        let listed = source.listedIDs()
        ids = listed ?? []
        isUnreadable = listed == nil
        unreadableLabel.stringValue = source.unreadableText
        scrollView.isHidden = isUnreadable
        unreadableNotice.isHidden = !isUnreadable
        tableView.reloadData()
        if let selected { select(selected) }
        refreshControls()
    }

    /// The selected item's identifier, `nil` when none is selected.
    var selectedID: UUID? {
        let row = tableView.selectedRow
        return ids.indices.contains(row) ? ids[row] : nil
    }

    /// Selects the item `id` identifies, scrolling it into view.
    func select(_ id: UUID) {
        guard let row = ids.firstIndex(of: id) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// The item whose row holds `view`, `nil` for a view in no row.
    func id(ofRowHolding view: NSView) -> UUID? {
        let row = tableView.row(for: view)
        return ids.indices.contains(row) ? ids[row] : nil
    }

    private func refreshControls() {
        addRemoveControl.setEnabled(!isUnreadable && source?.canCreate == true, forSegment: Self.addSegment)
        addRemoveControl.setEnabled(selectedID != nil, forSegment: Self.removeSegment)
    }

    // MARK: - Actions

    @objc private func checkConfigFiles() {
        source?.showConfigCheck()
    }

    @objc private func addRemoveClicked() {
        switch addRemoveControl.selectedSegment {
        case Self.addSegment: create()
        case Self.removeSegment: deleteSelected()
        default: break
        }
    }

    /// Asks the source for a new item, committing an open rename first.
    ///
    /// The +/− control takes no focus, so a click on it leaves an open rename
    /// open; the pane's own changes end it before they run.
    func create() {
        openRename?.endRename()
        source?.presentCreate()
    }

    /// Asks before deleting the selected item, committing an open rename
    /// first, so the question names the item as renamed.
    func deleteSelected() {
        openRename?.endRename()
        confirmDelete()
    }

    /// Opens the rename of the item `id` identifies, selecting it, the box
    /// holding `draft` in place of its name when one is given.
    private func beginRename(of id: UUID, holding draft: String? = nil) {
        guard let row = ids.firstIndex(of: id) else { return }
        select(id)
        (tableView.view(atColumn: tableView.column(withIdentifier: nameColumn), row: row, makeIfNecessary: true)
            as? SettingsNamedListNameCellView)?.beginRename(holding: draft)
    }

    /// Renames the item `id` identifies to `typed`, the text its rename was
    /// committed with, then repaints the list with every change that arrived
    /// during the edit. A name the source refuses opens the rename again,
    /// holding that name, once the refusal is dismissed.
    private func commitRename(of id: UUID, to typed: String) {
        if let source, typed != source.name(of: id) {
            run(
                "Couldn\u{2019}t Rename the \(noun)",
                retry: { [weak self] in self?.beginRename(of: id, holding: typed) }
            ) { try source.rename(id, to: typed) }
        }
        repaint()
    }

    private func confirmDelete() {
        guard let window = tableView.window, let id = selectedID,
            let confirmation = source?.deleteConfirmation(
                for: id,
                delete: { [weak self] in
                    self?.attempt("Couldn\u{2019}t Delete the \(self?.noun ?? "")") { try self?.source?.delete(id) }
                })
        else { return }
        presentSheetAlert(confirmation, in: window)
    }

    /// Runs one of the pane's own changes: ends a name edit in progress,
    /// committing it, then runs `change` and repaints. What it was refused
    /// with is shown under `title`.
    func attempt(_ title: String, _ change: () throws -> Void) {
        openRename?.endRename()
        run(title, change)
        reload()
    }

    /// Runs `change`, showing what it was refused with under `title`, then
    /// `retry` once that sheet is dismissed.
    private func run(_ title: String, retry: (() -> Void)? = nil, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            let message = (error as? CommandError)?.message ?? error.localizedDescription
            logger.log(.notice, "\(title, privacy: .public): \(message, privacy: .public)")
            guard let window = tableView.window else { return }
            presentSheetAlert(.acknowledgement(title: title, message: message), in: window, completion: retry)
        }
    }

    /// The control's add and remove glyphs, logging and asserting on a
    /// missing one while degrading to no image in Release.
    private func symbol(_ name: NSImage.Name) -> NSImage? {
        guard let image = NSImage(named: name) else {
            logger.log(
                .fault, "Missing image '\(name, privacy: .public)' for the \(self.noun, privacy: .public) list")
            assertionFailure("Missing image: \(name)")
            return nil
        }
        return image
    }
}

// MARK: - NSTableViewDataSource

extension SettingsNamedListEditor: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        ids.count
    }
}

// MARK: - NSTableViewDelegate

extension SettingsNamedListEditor: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, ids.indices.contains(row), let source else { return nil }
        let id = ids[row]
        if identifier == nameColumn {
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? SettingsNamedListNameCellView
                ?? SettingsNamedListNameCellView(identifier: identifier)
            cell.configure(
                name: source.name(of: id),
                renaming: .init(
                    commit: { [weak self] typed in self?.commitRename(of: id, to: typed) },
                    // The edit's end repaints what arrived during it.
                    cancel: { [weak self] in self?.repaint() }))
            return cell
        }
        if let control = source.control(for: identifier, of: id) { return control }
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeTextCell(identifier)
        cell.textField?.stringValue = source.text(for: identifier, of: id)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // A pending slow-second-click rename was armed on the old selection.
        self.tableView.renameClicks?.cancel()
        refreshControls()
    }

    /// A cell whose one field shows the column's value.
    private func makeTextCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.allowsExpansionToolTips = true
        field.textColor = .secondaryLabelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Spacing.tight),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Spacing.tight),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Table

/// A ``SettingsNamedListEditor``'s table, whose clicks open a row's rename
/// through ``renameClicks``.
@MainActor
final class SettingsNamedListTableView: NSTableView {
    /// Set by the editor, which answers for the rows.
    fileprivate(set) var renameClicks: InPlaceRenameClicks<UUID>?

    override func mouseDown(with event: NSEvent) {
        guard let renameClicks else { return super.mouseDown(with: event) }
        renameClicks.mouseDown(with: event) {
            super.mouseDown(with: $0)
            return self.window?.mouseLocationOutsideOfEventStream ?? $0.locationInWindow
        }
    }
}
