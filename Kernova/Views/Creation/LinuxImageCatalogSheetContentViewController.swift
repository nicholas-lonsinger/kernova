import AppKit
import Foundation

/// Delegate for ``LinuxImageCatalogSheetContentViewController``.
@MainActor
protocol LinuxImageCatalogSheetContentViewControllerDelegate: AnyObject {
    /// The user committed a distribution, by Choose or by double-click.
    func linuxImageCatalogSheet(
        _ vc: LinuxImageCatalogSheetContentViewController,
        didChoose entry: LinuxImageCatalogEntry
    )

    /// The user dismissed without choosing.
    func linuxImageCatalogSheetDidCancel(
        _ vc: LinuxImageCatalogSheetContentViewController
    )
}

/// Nested sheet listing every Linux installer image in the bundled catalog.
///
/// Every row is selectable: the catalog carries arm64 images only, so there is
/// no host-compatibility verdict to render.
@MainActor
final class LinuxImageCatalogSheetContentViewController: NSViewController {
    weak var delegate: LinuxImageCatalogSheetContentViewControllerDelegate?

    /// Every entry the catalog offers, in display order.
    private let entries: [LinuxImageCatalogEntry]
    /// The rows currently shown, after the search filter.
    private(set) var visibleEntries: [LinuxImageCatalogEntry]
    private let generatedAt: String?
    private let isDownloaded: @MainActor (LinuxImageCatalogEntry) -> Bool
    /// Entry to select once the table exists, from a previous pick.
    private let pendingSelectedID: String?

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
        static let distribution = NSUserInterfaceItemIdentifier("distribution")
        static let version = NSUserInterfaceItemIdentifier("version")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let status = NSUserInterfaceItemIdentifier("status")
    }

    /// Builds the picker over `entries`, preselecting `selectedID`.
    ///
    /// `isDownloaded` reports whether an image for the entry is already in the
    /// user's Downloads folder, and defaults to matching that folder's contents
    /// against the entry's glob — the exact filename is a mirror's to decide, so
    /// there is no single path to probe the way the macOS picker has.
    init(
        entries: [LinuxImageCatalogEntry],
        selectedID: String? = nil,
        generatedAt: String? = nil,
        isDownloaded: (@MainActor (LinuxImageCatalogEntry) -> Bool)? = nil
    ) {
        // Sorted here so the rows read in catalog order whatever order they
        // arrive in.
        let ordered = entries.sorted(by: LinuxImageCatalogEntry.isOrderedBefore)
        self.entries = ordered
        self.visibleEntries = ordered
        self.generatedAt = generatedAt
        self.isDownloaded = isDownloaded ?? { Self.downloadsHoldsImage(for: $0) }
        self.pendingSelectedID = selectedID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LinuxImageCatalogSheetContentViewController does not support NSCoder")
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

        let title = NSTextField(labelWithString: "Choose a Distribution")
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
            (Column.distribution, "Distribution", CGFloat(190)),
            (Column.version, "Version", CGFloat(110)),
            (Column.size, "Size", CGFloat(120)),
            (Column.status, "Status", CGFloat(130)),
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
        // Automatic content insets stay ON: the reserved space at the top is
        // what the column header occupies, and zeroing it renders the first row
        // underneath the header instead of below it.
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
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"  // Escape

        chooseButton.title = "Choose"
        chooseButton.target = self
        chooseButton.action = #selector(chooseTapped)
        chooseButton.bezelStyle = .push
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

    /// Tells the user how fresh the list is, and where to go for anything it
    /// doesn't offer.
    ///
    /// The catalog ships as a snapshot, so a release that postdates this build
    /// is not on it — and neither is any distribution outside the curated set.
    private var footerNote: String {
        guard let generatedAt, let date = Self.catalogDateFormatter.date(from: generatedAt) else {
            return "For a distribution this list doesn't offer, use ISO File"
        }
        let month = date.formatted(.dateTime.month(.wide).year())
        return "List current as of \(month) — for anything else, use ISO File"
    }

    // MARK: - Selection

    private func selectInitialRow() {
        let target =
            pendingSelectedID.flatMap { id in
                visibleEntries.firstIndex { $0.id == id }
            } ?? (visibleEntries.isEmpty ? nil : 0)
        guard let target else { return }
        tableView.selectRowIndexes([target], byExtendingSelection: false)
        tableView.scrollRowToVisible(target)
    }

    /// The entry the user has settled on, or `nil` when nothing is selected.
    var selectedEntry: LinuxImageCatalogEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < visibleEntries.count else { return nil }
        return visibleEntries[row]
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
        let previouslySelected = selectedEntry?.id
        visibleEntries = entries.filter { $0.matches(searchTerm: term) }
        tableView.reloadData()
        if let previouslySelected,
            let row = visibleEntries.firstIndex(where: { $0.id == previouslySelected })
        {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        updateChooseEnabled()
    }

    @objc private func cancelTapped() {
        delegate?.linuxImageCatalogSheetDidCancel(self)
    }

    @objc private func chooseTapped() {
        guard let entry = selectedEntry else { return }
        delegate?.linuxImageCatalogSheet(self, didChoose: entry)
    }

    @objc private func rowDoubleClicked() {
        // `clickedRow` is -1 when the double-click landed on the header or on
        // empty space below the last row.
        guard tableView.clickedRow >= 0 else { return }
        chooseTapped()
    }

    // MARK: - Helpers

    /// Whether the user's Downloads folder already holds an image this entry
    /// names.
    ///
    /// A completed download is the only thing that can match: an interrupted one
    /// keeps its bytes in a `.kernovadownload` bundle beside the destination,
    /// which the entry's `.iso`-anchored glob does not take.
    private static func downloadsHoldsImage(for entry: LinuxImageCatalogEntry) -> Bool {
        let downloads = VMCreationViewModel.downloadsDirectory.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: downloads) else {
            return false
        }
        return names.contains { entry.matchesISOFilename($0) }
    }

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

extension LinuxImageCatalogSheetContentViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }
}

// MARK: - NSTableViewDelegate

extension LinuxImageCatalogSheetContentViewController: NSTableViewDelegate {
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateChooseEnabled()
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn, row >= 0, row < visibleEntries.count else { return nil }
        let entry = visibleEntries[row]

        let identifier = NSUserInterfaceItemIdentifier("LinuxImageCatalogCell")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? makeCellView(identifier: identifier)
        cell.textField?.stringValue = text(for: entry, column: tableColumn.identifier)
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
        for entry: LinuxImageCatalogEntry, column: NSUserInterfaceItemIdentifier
    ) -> String {
        switch column {
        case Column.distribution:
            return entry.distribution
        case Column.version:
            return entry.version
        case Column.size:
            return wizardApproximateSize(entry.approxSizeBytes)
        case Column.status:
            return isDownloaded(entry) ? "In Downloads" : ""
        default:
            return ""
        }
    }
}
