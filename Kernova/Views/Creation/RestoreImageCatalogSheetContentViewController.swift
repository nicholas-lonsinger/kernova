import AppKit
import Foundation

/// Delegate for ``RestoreImageCatalogSheetContentViewController``.
@MainActor
protocol RestoreImageCatalogSheetContentViewControllerDelegate: AnyObject {
    /// The user committed a version, by Choose or by double-click.
    func restoreImageCatalogSheet(
        _ vc: RestoreImageCatalogSheetContentViewController,
        didChoose entry: RestoreImageCatalogEntry
    )

    /// The user dismissed without choosing.
    func restoreImageCatalogSheetDidCancel(
        _ vc: RestoreImageCatalogSheetContentViewController
    )
}

/// Nested sheet listing every macOS restore image in the bundled catalog.
///
/// Rows for guests newer than this host are dimmed and unselectable:
/// Virtualization refuses a guest above the host, and the framework's own
/// verdict is unavailable until the image is downloaded.
@MainActor
final class RestoreImageCatalogSheetContentViewController: NSViewController {
    weak var delegate: RestoreImageCatalogSheetContentViewControllerDelegate?

    /// Every entry the catalog offers, newest first.
    private let entries: [RestoreImageCatalogEntry]
    /// The rows currently shown, after the search filter.
    private(set) var visibleEntries: [RestoreImageCatalogEntry]
    private let generatedAt: String?
    private let hostVersion: OperatingSystemVersion
    private let isDownloaded: @MainActor (RestoreImageCatalogEntry) -> Bool
    /// Build to select once the table exists, from a previous pick.
    private let pendingSelectedBuild: String?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let chooseButton = NSButton()

    // MARK: - Layout constants

    private static let sheetWidth: CGFloat = 620
    private static let sheetHeight: CGFloat = 440
    private static let padding: CGFloat = 16
    private static let rowHeight: CGFloat = 24

    private enum Column {
        static let version = NSUserInterfaceItemIdentifier("version")
        static let build = NSUserInterfaceItemIdentifier("build")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let released = NSUserInterfaceItemIdentifier("released")
        static let status = NSUserInterfaceItemIdentifier("status")
    }

    /// Builds the picker over `entries`, preselecting `selectedBuild`.
    ///
    /// `isDownloaded` reports whether an entry's image already sits at its
    /// download destination — the same check that drives the wizard's overwrite
    /// banner — and defaults to a `FileManager` probe of that path.
    init(
        entries: [RestoreImageCatalogEntry],
        selectedBuild: String? = nil,
        generatedAt: String? = nil,
        hostVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        isDownloaded: (@MainActor (RestoreImageCatalogEntry) -> Bool)? = nil
    ) {
        self.entries = entries
        self.visibleEntries = entries
        self.generatedAt = generatedAt
        self.hostVersion = hostVersion
        self.isDownloaded =
            isDownloaded
            ?? { entry in
                FileManager.default.fileExists(
                    atPath: VMCreationViewModel.downloadPath(forFilename: entry.suggestedFilename))
            }
        self.pendingSelectedBuild = selectedBuild
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RestoreImageCatalogSheetContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let divider1 = makeHorizontalSeparator()
        let body = makeTableSection()
        let divider2 = makeHorizontalSeparator()
        let footer = makeFooter()

        for subview in [header, divider1, body, divider2, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            container.heightAnchor.constraint(equalToConstant: Self.sheetHeight),

            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider1.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            body.topAnchor.constraint(equalTo: divider1.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider2.topAnchor.constraint(equalTo: body.bottomAnchor),
            divider2.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            footer.topAnchor.constraint(equalTo: divider2.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
        selectInitialRow()
        updateChooseEnabled()
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "Choose a macOS Version")
        title.font = .preferredFont(forTextStyle: .headline)
        title.isSelectable = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, spacer, searchField])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Spacing.standard
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(equalToConstant: 190),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])
        return container
    }

    // MARK: - Table

    private func makeTableSection() -> NSView {
        for (identifier, title, width) in [
            (Column.version, "Version", CGFloat(150)),
            (Column.build, "Build", CGFloat(84)),
            (Column.size, "Size", CGFloat(74)),
            (Column.released, "Released", CGFloat(100)),
            (Column.status, "Status", CGFloat(140)),
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
        }

        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowHeight = Self.rowHeight
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = []
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = NSEdgeInsetsZero
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - Footer

    private func makeFooter() -> NSView {
        let container = NSView()

        let note = NSTextField(labelWithString: footerNote)
        note.font = .preferredFont(forTextStyle: .caption1)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.isSelectable = false
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"  // Escape

        chooseButton.title = "Choose"
        chooseButton.target = self
        chooseButton.action = #selector(chooseTapped)
        chooseButton.bezelStyle = .rounded
        chooseButton.keyEquivalent = "\r"  // Return = default action

        let stack = NSStackView(views: [note, spacer, cancel, chooseButton])
        stack.orientation = .horizontal
        stack.spacing = Spacing.standard
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])
        return container
    }

    /// Tells the user how fresh the list is, and where to go for anything newer.
    ///
    /// The catalog ships as a snapshot, so the newest release Apple has today
    /// may postdate this build — "Download Latest" always resolves live.
    private var footerNote: String {
        guard let generatedAt, let date = Self.catalogDateFormatter.date(from: generatedAt) else {
            return "For a newer release than this list offers, use Download Latest"
        }
        let month = date.formatted(.dateTime.month(.wide).year())
        return "List current as of \(month) — for anything newer, use Download Latest"
    }

    // MARK: - Selection

    private func selectInitialRow() {
        let target =
            pendingSelectedBuild.flatMap { build in
                visibleEntries.firstIndex { $0.build == build }
            } ?? visibleEntries.firstIndex { isSelectable($0) }
        guard let target else { return }
        tableView.selectRowIndexes([target], byExtendingSelection: false)
        tableView.scrollRowToVisible(target)
    }

    /// The entry the user has settled on, or `nil` when nothing selectable is
    /// selected.
    var selectedEntry: RestoreImageCatalogEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < visibleEntries.count else { return nil }
        let entry = visibleEntries[row]
        return isSelectable(entry) ? entry : nil
    }

    private func isSelectable(_ entry: RestoreImageCatalogEntry) -> Bool {
        entry.isSupported(onHost: hostVersion)
    }

    private func updateChooseEnabled() {
        chooseButton.isEnabled = selectedEntry != nil
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        applyFilter(searchField.stringValue)
    }

    /// Re-filters the rows, keeping the current selection when it survives.
    func applyFilter(_ term: String) {
        let previouslySelected = selectedEntry?.build
        visibleEntries = entries.filter { $0.matches(searchTerm: term) }
        tableView.reloadData()
        if let previouslySelected,
            let row = visibleEntries.firstIndex(where: { $0.build == previouslySelected })
        {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        updateChooseEnabled()
    }

    @objc private func cancelTapped() {
        delegate?.restoreImageCatalogSheetDidCancel(self)
    }

    @objc private func chooseTapped() {
        guard let entry = selectedEntry else { return }
        delegate?.restoreImageCatalogSheet(self, didChoose: entry)
    }

    @objc private func rowDoubleClicked() {
        // `clickedRow` is -1 when the double-click landed on the header or on
        // empty space below the last row.
        guard tableView.clickedRow >= 0 else { return }
        chooseTapped()
    }

    // MARK: - Helpers

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// The catalog's `generatedAt`, in the fixed format the generator emits.
    private static let catalogDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - NSTableViewDataSource

extension RestoreImageCatalogSheetContentViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }
}

// MARK: - NSTableViewDelegate

extension RestoreImageCatalogSheetContentViewController: NSTableViewDelegate {
    /// Blocks selection of a guest the host cannot run.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < visibleEntries.count else { return false }
        return isSelectable(visibleEntries[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateChooseEnabled()
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn, row >= 0, row < visibleEntries.count else { return nil }
        let entry = visibleEntries[row]

        let identifier = NSUserInterfaceItemIdentifier("RestoreImageCatalogCell")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCellView(identifier: identifier)
        cell.textField?.stringValue = text(for: entry, column: tableColumn.identifier)
        cell.textField?.textColor = isSelectable(entry) ? .labelColor : .tertiaryLabelColor
        return cell
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.font = Typography.body
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Spacing.tight),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Spacing.tight),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func text(
        for entry: RestoreImageCatalogEntry, column: NSUserInterfaceItemIdentifier
    ) -> String {
        switch column {
        case Column.version:
            return "macOS \(entry.version)"
        case Column.build:
            return entry.build
        case Column.size:
            return DataFormatters.formatBytes(entry.sizeBytes)
        case Column.released:
            return entry.releaseDate.map { $0.formatted(.dateTime.month(.abbreviated).day().year()) }
                ?? "—"
        case Column.status:
            return statusText(for: entry)
        default:
            return ""
        }
    }

    private func statusText(for entry: RestoreImageCatalogEntry) -> String {
        guard isSelectable(entry) else { return "Needs macOS \(entry.version)" }
        if isDownloaded(entry) { return "In Downloads" }
        if entry.build == entries.first?.build { return "Latest" }
        return ""
    }
}
