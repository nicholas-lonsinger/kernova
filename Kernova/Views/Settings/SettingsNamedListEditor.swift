import AppKit
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

/// A Settings pane's list of the library's named items: a table whose name
/// column takes an inline rename, a +/− control that creates through the
/// source and deletes after its confirmation, and an observation loop, live
/// while the pane is on screen, that repaints the list on any change.
///
/// A refusal is shown as a sheet on the Settings window. A change arriving
/// while a name is being edited repaints once the edit ends, since a reload
/// would end the edit. While the list can't be read, a notice pointing to the
/// config file check stands in for it, and the control offers nothing.
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

    let tableView = NSTableView()
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
    /// The name field the window's field editor is editing, from the moment
    /// it opens — before anything is typed.
    private var editingNameField: NSTextField? {
        guard let editor = tableView.window?.firstResponder as? NSText,
            let field = editor.delegate as? NSTextField, field.isDescendant(of: tableView)
        else { return nil }
        return field
    }
    private var observation: ObservationLoop?

    init(
        noun: String, columns: [Column], nameColumn: NSUserInterfaceItemIdentifier, logger: KernovaLogger,
        source: any SettingsNamedListSource
    ) {
        self.noun = noun
        self.nameColumn = nameColumn
        self.logger = logger
        self.source = source
        super.init()
        configureTable(columns)
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

    private func configureTable(_ columns: [Column]) {
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
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
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
    }

    // MARK: - List

    /// Re-reads the items and repaints the list, keeping the selection on the
    /// item it was on.
    func reload() {
        // A reload would end the edit; the edit's end repaints instead.
        guard editingNameField == nil else { return }
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
        case Self.addSegment: source?.presentCreate()
        case Self.removeSegment: confirmDelete()
        default: break
        }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0,
            let cell = tableView.view(
                atColumn: tableView.column(withIdentifier: nameColumn), row: row, makeIfNecessary: false)
                as? NSTableCellView
        else { return }
        cell.textField?.selectText(nil)
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

    /// Runs `change`, then repaints; what it was refused with is shown under
    /// `title`.
    func attempt(_ title: String, _ change: () throws -> Void) {
        do {
            try change()
            reload()
        } catch {
            let message = (error as? CommandError)?.message ?? error.localizedDescription
            #log(logger, .notice, "\(title, privacy: .public): \(message, privacy: .public)")
            reload()
            guard let window = tableView.window else { return }
            presentSheetAlert(.acknowledgement(title: title, message: message), in: window)
        }
    }

    /// The control's add and remove glyphs, logging and asserting on a
    /// missing one while degrading to no image in Release.
    private func symbol(_ name: NSImage.Name) -> NSImage? {
        guard let image = NSImage(named: name) else {
            #log(
                logger, .fault, "Missing image '\(name, privacy: .public)' for the \(self.noun, privacy: .public) list")
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
        if let control = source.control(for: identifier, of: id) { return control }
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
        cell.textField?.allowsExpansionToolTips = true
        cell.textField?.stringValue =
            identifier == nameColumn ? source.name(of: id) : source.text(for: identifier, of: id)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshControls()
    }

    /// A cell whose one field shows the column's value; the name's field is
    /// where a rename is typed.
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        if identifier == nameColumn {
            field.isEditable = true
            field.delegate = self
        } else {
            field.textColor = .secondaryLabelColor
        }
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

// MARK: - NSTextFieldDelegate

extension SettingsNamedListEditor: NSTextFieldDelegate {
    /// Commits a rename typed into a name cell, then repaints the list with
    /// every change that arrived during the edit; a name the source refuses
    /// puts the item's name back.
    ///
    /// AppKit sends this whether or not anything was typed, while the field
    /// editor is still the window's first responder — so ``reload()`` called
    /// from here still waits, and the repaint is this method's own.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let source else { return }
        let row = tableView.row(for: field)
        if ids.indices.contains(row), field.stringValue != source.name(of: ids[row]) {
            let id = ids[row]
            let name = field.stringValue
            attempt("Couldn\u{2019}t Rename the \(noun)") { try source.rename(id, to: name) }
        }
        repaint()
    }
}
