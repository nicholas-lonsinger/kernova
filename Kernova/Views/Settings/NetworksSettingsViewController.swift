import AppKit
import KernovaKit
import KernovaLogging

/// The "Networks" pane of the Settings window: the library's named networks,
/// each created, renamed and deleted here and chosen per VM in its Network
/// settings.
///
/// Every change goes through the command facade, so the pane, the CLI and
/// every other surface share one set of refusals. The list is a
/// ``SettingsNamedListEditor``.
@MainActor
final class NetworksSettingsViewController: NSViewController {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "NetworksSettingsViewController")

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let kindColumn = NSUserInterfaceItemIdentifier("kind")
    private static let membersColumn = NSUserInterfaceItemIdentifier("members")

    private let viewModel: VMLibraryViewModel

    /// The networks the table shows, as the facade reports them.
    private(set) var networks: [NetworkSummary] = []

    private lazy var editor = SettingsNamedListEditor(
        noun: "Network",
        columns: [
            .init(id: Self.nameColumn, title: "Name", width: 150),
            .init(id: Self.kindColumn, title: "Mode", width: 110),
            .init(id: Self.membersColumn, title: "Virtual Machines", width: 200),
        ],
        nameColumn: Self.nameColumn, logger: Self.logger, source: self)

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
        editor.reload()
        editor.select(created.id)
    }

    /// Renames the network `id` identifies.
    func rename(_ id: UUID, to name: String) throws {
        try viewModel.commands.renameNetwork(id.uuidString, to: name)
        editor.reload()
    }

    /// Deletes the network `id` identifies, moving each VM on it to a network
    /// of its own.
    func delete(_ id: UUID) throws {
        try viewModel.commands.deleteNetwork(id.uuidString)
        editor.reload()
    }

    // MARK: - View

    override func loadView() {
        view = editor.makePaneView(
            header: "Named Networks",
            caption: "Virtual machines on the same named network reach each other there, and no other "
                + "virtual machine reaches them. Choose a virtual machine\u{2019}s network in its "
                + "Network settings.")
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
                        self?.editor.attempt("Couldn\u{2019}t Create the Network") {
                            try self?.create(name: nameField.stringValue, kind: kind)
                        }
                    },
                    AlertButton("Cancel", role: .cancel),
                ],
                accessoryView: grid, initialFirstResponder: nameField),
            in: window)
    }
}

// MARK: - SettingsNamedListSource

extension NetworksSettingsViewController: SettingsNamedListSource {
    func listedIDs() -> [UUID] {
        networks = viewModel.commands.networks()
        return networks.map(\.id)
    }

    private func network(_ id: UUID) -> NetworkSummary? {
        networks.first { $0.id == id }
    }

    func name(of id: UUID) -> String {
        network(id)?.name ?? ""
    }

    func text(for column: NSUserInterfaceItemIdentifier, of id: UUID) -> String {
        guard let network = network(id) else { return "" }
        return column == Self.kindColumn ? Self.kindTitle(network.kind) : Self.membersText(network.members)
    }

    func control(for column: NSUserInterfaceItemIdentifier, of id: UUID) -> NSView? {
        nil
    }

    func readListedValues() {
        _ = viewModel.commands.networks()
    }

    var canCreate: Bool {
        !Self.creatableKinds(viewModel.entitlements).isEmpty
    }

    func presentCreate() {
        presentNewNetworkSheet()
    }

    func deleteConfirmation(for id: UUID, delete: @escaping () -> Void) -> AlertConfiguration? {
        network(id).map { Self.deleteConfirmation(for: $0, delete: delete) }
    }
}
