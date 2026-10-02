import AppKit
import KernovaKit
import KernovaLogging

/// The "Networks" pane of the Settings window: the library's named networks,
/// each created, renamed and deleted here and chosen per VM in its Network
/// settings.
///
/// Every change goes through the command facade, so the pane, the CLI and
/// every other surface share one set of refusals; a refusal is shown as a
/// sheet on the Settings window. An observation loop, live while the pane is
/// on screen, repaints the list whenever a network or a VM's network changes.
@MainActor
final class NetworksSettingsViewController: NSViewController {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "NetworksSettingsViewController")

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let kindColumn = NSUserInterfaceItemIdentifier("kind")
    private static let membersColumn = NSUserInterfaceItemIdentifier("members")

    private let viewModel: VMLibraryViewModel

    private let tableView = NSTableView()
    private let addRemoveControl = NSSegmentedControl()
    private static let addSegment = 0
    private static let removeSegment = 1

    /// The networks the table shows, as the facade reports them.
    private(set) var networks: [NetworkSummary] = []
    /// The name field being edited, while one is: a reload would end its
    /// edit, so a change arriving meanwhile reloads once it ends.
    private var editingNameField: NSTextField?
    private var reloadAfterEditing = false
    private var observation: ObservationLoop?

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Networks"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NetworksSettingsViewController does not support NSCoder")
    }

    // MARK: - Model

    /// The kinds of network this build can attach a named network of, in the
    /// order the New Network sheet lists them — empty in a build that can
    /// attach none, which offers no Networks pane.
    static func creatableKinds(_ entitlements: EntitlementService) -> [VmnetNetworkKind] {
        [VmnetNetworkKind.shared, .hostOnly].filter {
            entitlements.canAttach(.vmnet(VmnetNetworkID(kind: $0, scope: .named(UUID()))))
        }
    }

    /// How the list names the VMs on a network.
    static func membersText(_ members: [VMSummary]) -> String {
        members.isEmpty ? "None" : members.map(\.name).joined(separator: ", ")
    }

    /// How the list names a network's kind.
    static func kindTitle(_ kind: NetworkKind) -> String {
        NetworkModeChoice.kindTitle(VmnetNetworkKind(kind))
    }

    /// The question Delete asks before `network` goes, naming the VMs on it.
    static func deleteConfirmation(
        for network: NetworkSummary, delete: @escaping () -> Void
    ) -> AlertConfiguration {
        let names = network.members.map(\.name)
        let message =
            switch names.count {
            case 0: "No virtual machine is on this network."
            case 1: "\(DataFormatters.quotedList(names)) moves to a network of its own."
            default: "\(DataFormatters.quotedList(names)) each move to a network of their own."
            }
        return AlertConfiguration(
            title: "Delete \u{201C}\(network.name)\u{201D}?", message: message,
            buttons: [
                AlertButton("Delete", role: .destructive, action: delete),
                AlertButton("Cancel", role: .cancel),
            ])
    }

    // MARK: - Changes

    /// Lists a new network named `name` of `kind`, selecting it.
    func create(name: String, kind: VmnetNetworkKind) throws {
        let created = try viewModel.commands.createNetwork(name: name, kind: NetworkKind(kind))
        reload()
        select(created.id)
    }

    /// Renames the network `id` identifies.
    func rename(_ id: UUID, to name: String) throws {
        try viewModel.commands.renameNetwork(id.uuidString, to: name)
        reload()
    }

    /// Deletes the network `id` identifies, moving each VM on it to a network
    /// of its own.
    func delete(_ id: UUID) throws {
        try viewModel.commands.deleteNetwork(id.uuidString)
        reload()
    }

    // MARK: - View

    override func loadView() {
        let header = makeGroupedFormSectionHeader("Named Networks")
        let caption = makeGroupedFormContentText(
            "Virtual machines on the same named network reach each other there, and no other "
                + "virtual machine reaches them. Choose a virtual machine\u{2019}s network in its "
                + "Network settings.")

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
        addRemoveControl.setImage(
            Self.symbol(NSImage.addTemplateName), forSegment: Self.addSegment)
        addRemoveControl.setImage(
            Self.symbol(NSImage.removeTemplateName), forSegment: Self.removeSegment)
        addRemoveControl.setToolTip("New Network", forSegment: Self.addSegment)
        addRemoveControl.setToolTip("Delete Network", forSegment: Self.removeSegment)
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
            (Self.nameColumn, "Name", 150),
            (Self.kindColumn, "Mode", 110),
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

    /// Repaints the list whenever a network is created, renamed or deleted,
    /// or a VM joins or leaves one — from this window, the main one, or the
    /// CLI.
    private func startObservation() {
        observation?.cancel()
        observation = observeRecurring(
            track: { [weak self] in _ = self?.viewModel.commands.networks() },
            apply: { [weak self] in self?.reload() })
    }

    /// Re-reads the networks and repaints the list, keeping the selection on
    /// the network it was on.
    private func reload() {
        guard editingNameField == nil else {
            reloadAfterEditing = true
            return
        }
        let selected = selectedNetwork?.id
        networks = viewModel.commands.networks()
        tableView.reloadData()
        if let selected { select(selected) }
        refreshControls()
    }

    private var selectedNetwork: NetworkSummary? {
        let row = tableView.selectedRow
        return networks.indices.contains(row) ? networks[row] : nil
    }

    private func select(_ id: UUID) {
        guard let row = networks.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func refreshControls() {
        addRemoveControl.setEnabled(
            !Self.creatableKinds(viewModel.entitlements).isEmpty, forSegment: Self.addSegment)
        addRemoveControl.setEnabled(selectedNetwork != nil, forSegment: Self.removeSegment)
    }

    // MARK: - Actions

    @objc private func addRemoveClicked() {
        switch addRemoveControl.selectedSegment {
        case Self.addSegment: presentNewNetworkSheet()
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

    /// Asks for the new network's name and kind.
    private func presentNewNetworkSheet() {
        guard let window = view.window else { return }
        let kinds = Self.creatableKinds(viewModel.entitlements)
        guard !kinds.isEmpty else { return }

        let nameField = NSTextField()
        nameField.placeholderString = "Name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let kindPopUp = NSPopUpButton()
        for kind in kinds {
            kindPopUp.addItem(withTitle: NetworkModeChoice.kindTitle(kind))
            kindPopUp.lastItem?.representedObject = kind
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Mode:"), kindPopUp],
        ])
        grid.rowSpacing = Spacing.standard
        grid.columnSpacing = Spacing.standard
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.setFrameSize(grid.fittingSize)

        presentSheetAlert(
            AlertConfiguration(
                title: "New Network",
                message:
                    "Its mode is fixed once it is created: every virtual machine on it runs in that mode.",
                buttons: [
                    AlertButton("Create", role: .default) { [weak self] in
                        guard let kind = kindPopUp.selectedItem?.representedObject as? VmnetNetworkKind
                        else { return }
                        self?.attempt("Couldn\u{2019}t Create the Network") {
                            try self?.create(name: nameField.stringValue, kind: kind)
                        }
                    },
                    AlertButton("Cancel", role: .cancel),
                ],
                accessoryView: grid, initialFirstResponder: nameField),
            in: window)
    }

    private func confirmDelete() {
        guard let window = view.window, let network = selectedNetwork else { return }
        presentSheetAlert(
            Self.deleteConfirmation(for: network) { [weak self] in
                self?.attempt("Couldn\u{2019}t Delete the Network") {
                    try self?.delete(network.id)
                }
            },
            in: window)
    }

    /// Runs `change`, showing what it was refused with under `title`.
    private func attempt(_ title: String, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            let message = (error as? CommandError)?.message ?? error.localizedDescription
            #log(Self.logger, .notice, "\(title, privacy: .public): \(message, privacy: .public)")
            reload()
            guard let window = view.window else { return }
            presentSheetAlert(.acknowledgement(title: title, message: message), in: window)
        }
    }

    /// The list's add and remove glyphs, logging and asserting on a missing
    /// one while degrading to no image in Release.
    private static func symbol(_ name: NSImage.Name) -> NSImage? {
        guard let image = NSImage(named: name) else {
            #log(logger, .fault, "Missing image '\(name, privacy: .public)' for the Networks list")
            assertionFailure("Missing image: \(name)")
            return nil
        }
        return image
    }
}

// MARK: - NSTableViewDataSource

extension NetworksSettingsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        networks.count
    }
}

// MARK: - NSTableViewDelegate

extension NetworksSettingsViewController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let identifier = tableColumn?.identifier, networks.indices.contains(row) else {
            return nil
        }
        let network = networks[row]
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCell(identifier)
        switch identifier {
        case Self.nameColumn: cell.textField?.stringValue = network.name
        case Self.kindColumn: cell.textField?.stringValue = Self.kindTitle(network.kind)
        default: cell.textField?.stringValue = Self.membersText(network.members)
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

extension NetworksSettingsViewController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        editingNameField = obj.object as? NSTextField
    }

    /// Commits a rename typed into a name cell; a name the facade refuses
    /// puts the network's name back.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        editingNameField = nil
        let row = tableView.row(for: field)
        if networks.indices.contains(row), field.stringValue != networks[row].name {
            let id = networks[row].id
            let name = field.stringValue
            attempt("Couldn\u{2019}t Rename the Network") { try rename(id, to: name) }
        }
        if reloadAfterEditing || networks.indices.contains(row) {
            reloadAfterEditing = false
            reload()
        }
    }
}
