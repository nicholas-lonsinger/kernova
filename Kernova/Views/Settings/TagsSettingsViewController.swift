import AppKit
import KernovaLogging

/// The "Tags" pane of the Settings window: the library's tags, each created,
/// renamed, recolored and deleted here and put on a VM from its row's Tags
/// menu in the sidebar.
///
/// A refusal is shown as a sheet on the Settings window. An observation loop,
/// live while the pane is on screen, repaints the list whenever a tag or a
/// VM's tags change.
@MainActor
final class TagsSettingsViewController: NSViewController {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "TagsSettingsViewController")

    private static let colorColumn = NSUserInterfaceItemIdentifier("color")
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let membersColumn = NSUserInterfaceItemIdentifier("members")

    private let viewModel: VMLibraryViewModel
    private var library: VMLibrary { viewModel.library }

    private let tableView = NSTableView()
    private let addRemoveControl = NSSegmentedControl()
    private static let addSegment = 0
    private static let removeSegment = 1

    /// The tags the table shows, in the library's order.
    private(set) var tags: [VMTag] = []
    /// The name field being edited, while one is: a reload would end its
    /// edit, so a change arriving meanwhile reloads once it ends.
    private var editingNameField: NSTextField?
    private var reloadAfterEditing = false
    private var observation: ObservationLoop?

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Tags"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TagsSettingsViewController does not support NSCoder")
    }

    // MARK: - Model

    /// The VMs carrying `tag`, in library order.
    func members(of tag: VMTag) -> [VMInstance] {
        library.instances.filter { library.tags(of: $0).contains(tag) }
    }

    /// How the list names the VMs carrying a tag.
    static func membersText(_ members: [VMInstance]) -> String {
        members.isEmpty ? "None" : members.map(\.name).joined(separator: ", ")
    }

    /// The question Delete asks before `tag` goes, naming the VMs carrying it.
    static func deleteConfirmation(
        for tag: VMTag, members: [VMInstance], delete: @escaping () -> Void
    ) -> AlertConfiguration {
        let names = members.map(\.name)
        let message =
            switch names.count {
            case 0: "No virtual machine carries this tag."
            default: "Deleting it takes it off \(DataFormatters.quotedList(names))."
            }
        return AlertConfiguration(
            title: "Delete \u{201C}\(tag.name)\u{201D}?", message: message,
            buttons: [
                AlertButton("Delete", role: .destructive, action: delete),
                AlertButton("Cancel", role: .cancel),
            ])
    }

    /// The color a new tag starts in: the first no tag shows yet, else the
    /// one after the last tag's.
    func suggestedColor() -> VMTagColor {
        let palette = VMTagColor.allCases
        if let unused = palette.first(where: { color in !tags.contains { $0.color == color } }) {
            return unused
        }
        let next = tags.last.flatMap { palette.firstIndex(of: $0.color) }.map { ($0 + 1) % palette.count } ?? 0
        return palette[next]
    }

    // MARK: - Changes

    /// Defines a new tag named `name` in `color`, selecting it.
    func create(name: String, color: VMTagColor) throws {
        let created = try library.createTag(named: name, color: color)
        reload()
        select(created.id)
    }

    /// Renames the tag `id` identifies.
    func rename(_ id: UUID, to name: String) throws {
        try library.renameTag(id, to: name)
        reload()
    }

    /// Shows the tag `id` identifies in `color`.
    func recolor(_ id: UUID, to color: VMTagColor) throws {
        try library.setColor(color, ofTag: id)
        reload()
    }

    /// Deletes the tag `id` identifies, taking it off every VM and out of
    /// every filter.
    func delete(_ id: UUID) throws {
        try library.deleteTag(id)
        reload()
    }

    // MARK: - View

    override func loadView() {
        let header = makeGroupedFormSectionHeader("Tags")
        let caption = makeGroupedFormContentText(
            "Put a tag on a virtual machine from its Tags menu in the sidebar. A virtual machine "
                + "shows a dot in the color of each tag it carries, and the sidebar\u{2019}s filter "
                + "and grouping can use them.")

        configureTable()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addRemoveControl.segmentCount = 2
        addRemoveControl.segmentStyle = .smallSquare
        addRemoveControl.trackingMode = .momentary
        addRemoveControl.setImage(Self.symbol(NSImage.addTemplateName), forSegment: Self.addSegment)
        addRemoveControl.setImage(Self.symbol(NSImage.removeTemplateName), forSegment: Self.removeSegment)
        addRemoveControl.setToolTip("New Tag", forSegment: Self.addSegment)
        addRemoveControl.setToolTip("Delete Tag", forSegment: Self.removeSegment)
        addRemoveControl.target = self
        addRemoveControl.action = #selector(addRemoveClicked)

        let content = NSStackView(views: [header, caption, scrollView, addRemoveControl])
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
        ])
        view = SettingsPaneRootView(content: root)
    }

    private func configureTable() {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Self.colorColumn, "Color", 110),
            (Self.nameColumn, "Name", 150),
            (Self.membersColumn, "Virtual Machines", 200),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
        startObservation()
        publishSettingsPaneSize()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        observation?.cancel()
        observation = nil
    }

    /// Repaints the list whenever a tag is created, renamed, recolored or
    /// deleted, or a VM's tags change — from this window or the main one.
    private func startObservation() {
        observation?.cancel()
        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.library.tags
                for instance in self.library.instances {
                    _ = instance.name
                    _ = instance.hostState.tags
                }
            },
            apply: { [weak self] in self?.reload() })
    }

    /// Re-reads the tags and repaints the list, keeping the selection on the
    /// tag it was on.
    func reload() {
        guard editingNameField == nil else {
            reloadAfterEditing = true
            return
        }
        let selected = selectedTag?.id
        tags = library.tags
        tableView.reloadData()
        if let selected { select(selected) }
        refreshControls()
    }

    private var selectedTag: VMTag? {
        let row = tableView.selectedRow
        return tags.indices.contains(row) ? tags[row] : nil
    }

    private func select(_ id: UUID) {
        guard let row = tags.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func refreshControls() {
        addRemoveControl.setEnabled(selectedTag != nil, forSegment: Self.removeSegment)
    }

    // MARK: - Actions

    @objc private func addRemoveClicked() {
        switch addRemoveControl.selectedSegment {
        case Self.addSegment: presentNewTagSheet()
        case Self.removeSegment: confirmDelete()
        default: break
        }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0,
            let cell = tableView.view(
                atColumn: tableView.column(withIdentifier: Self.nameColumn), row: row,
                makeIfNecessary: false) as? NSTableCellView
        else { return }
        cell.textField?.selectText(nil)
    }

    @objc private func colorPicked(_ sender: NSPopUpButton) {
        let row = tableView.row(for: sender)
        guard tags.indices.contains(row),
            let color = sender.selectedItem?.representedObject as? VMTagColor,
            color != tags[row].color
        else { return }
        let id = tags[row].id
        attempt("Couldn\u{2019}t Change the Tag\u{2019}s Color") { try recolor(id, to: color) }
    }

    /// Asks for the new tag's name and color, starting from an unused name
    /// and ``suggestedColor()``.
    private func presentNewTagSheet() {
        guard let window = view.window else { return }
        let nameField = NSTextField()
        nameField.stringValue = library.organization.unusedName(from: "Untitled Tag", for: .tag)
        nameField.placeholderString = "Name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let colorPopUp = Self.colorPopUp(selecting: suggestedColor())
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Color:"), colorPopUp],
        ])
        grid.rowSpacing = Spacing.standard
        grid.columnSpacing = Spacing.standard
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.setFrameSize(grid.fittingSize)

        presentSheetAlert(
            AlertConfiguration(
                title: "New Tag",
                message: "Put it on a virtual machine from the Tags menu of its row in the sidebar.",
                buttons: [
                    AlertButton("Create", role: .default) { [weak self] in
                        guard let color = colorPopUp.selectedItem?.representedObject as? VMTagColor else {
                            return
                        }
                        self?.attempt("Couldn\u{2019}t Create the Tag") {
                            try self?.create(name: nameField.stringValue, color: color)
                        }
                    },
                    AlertButton("Cancel", role: .cancel),
                ],
                accessoryView: grid, initialFirstResponder: nameField),
            in: window)
    }

    private func confirmDelete() {
        guard let window = view.window, let tag = selectedTag else { return }
        presentSheetAlert(
            Self.deleteConfirmation(for: tag, members: members(of: tag)) { [weak self] in
                self?.attempt("Couldn\u{2019}t Delete the Tag") { try self?.delete(tag.id) }
            },
            in: window)
    }

    /// Runs `change`, showing what it was refused with under `title`.
    private func attempt(_ title: String, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            let message = error.localizedDescription
            #log(Self.logger, .notice, "\(title, privacy: .public): \(message, privacy: .public)")
            reload()
            guard let window = view.window else { return }
            presentSheetAlert(.acknowledgement(title: title, message: message), in: window)
        }
    }

    /// A pop-up listing every tag color with its dot, `selected` chosen.
    static func colorPopUp(selecting selected: VMTagColor) -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for color in VMTagColor.allCases {
            popUp.addItem(withTitle: color.title)
            popUp.lastItem?.representedObject = color
            popUp.lastItem?.image = color.dotImage()
        }
        popUp.selectItem(at: VMTagColor.allCases.firstIndex(of: selected) ?? 0)
        popUp.setAccessibilityLabel("Color")
        return popUp
    }

    /// The list's add and remove glyphs, logging and asserting on a missing
    /// one while degrading to no image in Release.
    private static func symbol(_ name: NSImage.Name) -> NSImage? {
        guard let image = NSImage(named: name) else {
            #log(logger, .fault, "Missing image '\(name, privacy: .public)' for the Tags list")
            assertionFailure("Missing image: \(name)")
            return nil
        }
        return image
    }
}

// MARK: - NSTableViewDataSource

extension TagsSettingsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tags.count
    }
}

// MARK: - NSTableViewDelegate

extension TagsSettingsViewController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let identifier = tableColumn?.identifier, tags.indices.contains(row) else {
            return nil
        }
        let tag = tags[row]
        if identifier == Self.colorColumn {
            let popUp = Self.colorPopUp(selecting: tag.color)
            popUp.identifier = Self.colorColumn
            popUp.isBordered = false
            popUp.target = self
            popUp.action = #selector(colorPicked(_:))
            popUp.setAccessibilityLabel("Color of \(tag.name)")
            return popUp
        }
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCell(identifier)
        cell.textField?.allowsExpansionToolTips = true
        switch identifier {
        case Self.nameColumn: cell.textField?.stringValue = tag.name
        default: cell.textField?.stringValue = Self.membersText(members(of: tag))
        }
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
        if identifier == Self.nameColumn {
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

extension TagsSettingsViewController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        editingNameField = obj.object as? NSTextField
    }

    /// Commits a rename typed into a name cell; a name the library refuses
    /// puts the tag's name back.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        editingNameField = nil
        let row = tableView.row(for: field)
        if tags.indices.contains(row), field.stringValue != tags[row].name {
            let id = tags[row].id
            let name = field.stringValue
            attempt("Couldn\u{2019}t Rename the Tag") { try rename(id, to: name) }
        }
        if reloadAfterEditing || tags.indices.contains(row) {
            reloadAfterEditing = false
            reload()
        }
    }
}
