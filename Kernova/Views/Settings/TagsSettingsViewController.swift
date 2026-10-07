import AppKit
import KernovaLogging

/// The "Tags" pane of the Settings window: the library's tags, each created,
/// renamed, recolored and deleted here and put on a VM from its row's Tags
/// menu in the sidebar. The list is a ``SettingsNamedListEditor``.
@MainActor
final class TagsSettingsViewController: NSViewController {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "TagsSettingsViewController")

    private static let colorColumn = NSUserInterfaceItemIdentifier("color")
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let membersColumn = NSUserInterfaceItemIdentifier("members")

    private let viewModel: VMLibraryViewModel
    private var library: VMLibrary { viewModel.library }

    /// The tags the table shows, in the library's order.
    private(set) var tags: [VMTag] = []

    private lazy var editor = SettingsNamedListEditor(
        noun: "Tag",
        columns: [
            .init(id: Self.colorColumn, title: "Color", width: 110),
            .init(id: Self.nameColumn, title: "Name", width: 150),
            .init(id: Self.membersColumn, title: "Virtual Machines", width: 200),
        ],
        nameColumn: Self.nameColumn, logger: Self.logger, source: self)

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

    /// The smart groups whose filter names `tag`.
    func smartGroups(filteringOn tag: VMTag) -> [VMSmartGroup] {
        library.smartGroups.filter { $0.filter.tags.contains(tag.id) }
    }

    /// How the list names the VMs carrying a tag.
    static func membersText(_ members: [VMInstance]) -> String {
        members.isEmpty ? "None" : members.map(\.name).joined(separator: ", ")
    }

    /// The question Delete asks before `tag` goes: the VMs it comes off, and
    /// the smart groups whose condition on it will match no VM.
    static func deleteConfirmation(
        for tag: VMTag, members: [VMInstance], smartGroups: [VMSmartGroup], delete: @escaping () -> Void
    ) -> AlertConfiguration {
        let names = members.map(\.name)
        var message =
            names.isEmpty
            ? "No virtual machine carries this tag."
            : "Deleting it takes it off \(DataFormatters.quotedList(names))."
        let groups = smartGroups.map(\.name)
        switch groups.count {
        case 0: break
        case 1:
            message +=
                " The smart group \(DataFormatters.quotedList(groups)) filters on it; "
                + "that condition will match no virtual machine."
        default:
            message +=
                " The smart groups \(DataFormatters.quotedList(groups)) filter on it; "
                + "those conditions will match no virtual machine."
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
        editor.reload()
        editor.select(created.id)
    }

    /// Renames the tag `id` identifies.
    func rename(_ id: UUID, to name: String) throws {
        try library.renameTag(id, to: name)
        editor.reload()
    }

    /// Shows the tag `id` identifies in `color`.
    func recolor(_ id: UUID, to color: VMTagColor) throws {
        try library.setColor(color, ofTag: id)
        editor.reload()
    }

    /// Deletes the tag `id` identifies, taking it off every VM.
    func delete(_ id: UUID) throws {
        try library.deleteTag(id)
        editor.reload()
    }

    // MARK: - View

    override func loadView() {
        view = editor.makePaneView(
            header: "Tags",
            caption: "Put a tag on a virtual machine from its Tags menu in the sidebar. A virtual machine "
                + "shows a dot in the color of each tag it carries, and the sidebar\u{2019}s filter "
                + "and grouping can use them.")
        editor.tableView.rowHeight = 24
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        editor.reload()
        editor.startObserving()
        publishSettingsPaneSize()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        editor.stopObserving()
    }

    @objc private func colorPicked(_ sender: NSPopUpButton) {
        guard let id = editor.id(ofRowHolding: sender),
            let color = sender.selectedItem?.representedObject as? VMTagColor,
            color != tags.first(where: { $0.id == id })?.color
        else { return }
        editor.attempt("Couldn\u{2019}t Change the Tag\u{2019}s Color") { try recolor(id, to: color) }
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
                        self?.editor.attempt("Couldn\u{2019}t Create the Tag") {
                            try self?.create(name: nameField.stringValue, color: color)
                        }
                    },
                    AlertButton("Cancel", role: .cancel),
                ],
                accessoryView: grid, initialFirstResponder: nameField),
            in: window)
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
            // The dot is the color the item picks, which macOS 27 hides
            // unless the item opts in (`NSMenuItem.h`).
            if #available(macOS 27, *) {
                popUp.lastItem?.preferredImageVisibility = .visible
            }
        }
        popUp.selectItem(at: VMTagColor.allCases.firstIndex(of: selected) ?? 0)
        popUp.setAccessibilityLabel("Color")
        return popUp
    }
}

// MARK: - SettingsNamedListSource

extension TagsSettingsViewController: SettingsNamedListSource {
    func listedIDs() -> [UUID]? {
        tags = library.tags
        return tags.map(\.id)
    }

    var unreadableText: String { "Kernova can\u{2019}t read its tags." }

    func showConfigCheck() {
        viewModel.showConfigCheck()
    }

    private func tag(_ id: UUID) -> VMTag? {
        tags.first { $0.id == id }
    }

    func name(of id: UUID) -> String {
        tag(id)?.name ?? ""
    }

    func text(for column: NSUserInterfaceItemIdentifier, of id: UUID) -> String {
        tag(id).map { Self.membersText(members(of: $0)) } ?? ""
    }

    func control(for column: NSUserInterfaceItemIdentifier, of id: UUID) -> NSView? {
        guard column == Self.colorColumn, let tag = tag(id) else { return nil }
        let popUp = Self.colorPopUp(selecting: tag.color)
        popUp.isBordered = false
        popUp.target = self
        popUp.action = #selector(colorPicked(_:))
        popUp.setAccessibilityLabel("Color of \(tag.name)")
        return popUp
    }

    func readListedValues() {
        _ = library.tags
        for instance in library.instances {
            _ = instance.name
            _ = instance.hostState.tags
        }
    }

    var canCreate: Bool { true }

    func presentCreate() {
        presentNewTagSheet()
    }

    func deleteConfirmation(for id: UUID, delete: @escaping () -> Void) -> AlertConfiguration? {
        tag(id).map {
            Self.deleteConfirmation(
                for: $0, members: members(of: $0), smartGroups: smartGroups(filteringOn: $0), delete: delete)
        }
    }
}
