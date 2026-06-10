import AppKit

/// Delegate for ``StorageDiskReorderSheetContentViewController``.
///
/// The view controller is intentionally decoupled from
/// `VMLibraryViewModel`; the host (the presenting view controller, e.g.
/// `VMSettingsViewController`) implements these methods and forwards the
/// user's choice to the view model.
@MainActor
protocol StorageDiskReorderSheetContentViewControllerDelegate: AnyObject {
    /// Invoked after a successful drag-reorder.
    ///
    /// - Parameters:
    ///   - vc: The sheet view controller firing the event.
    ///   - disks: The new ordering of disks, top to bottom.
    func storageDiskReorderSheet(
        _ vc: StorageDiskReorderSheetContentViewController,
        didReorderTo disks: [StorageDisk]
    )

    /// Invoked when the user clicks Done (or presses Return).
    func storageDiskReorderSheetDidDismiss(
        _ vc: StorageDiskReorderSheetContentViewController
    )
}

/// AppKit Boot Order sheet: shows a draggable list of the VM's storage
/// disks so the user can change boot priority / guest device
/// enumeration order.
///
/// Drag-anywhere reorder via the native `NSTableView` drag-and-drop
/// machinery (`pasteboardWriterForRow:`, `validateDrop:`, `acceptDrop:`)
/// — no visible drag handle, since AppKit list reorder is conventionally
/// discoverable through direct manipulation (Finder, Mail).
@MainActor
final class StorageDiskReorderSheetContentViewController: NSViewController {
    weak var delegate: StorageDiskReorderSheetContentViewControllerDelegate?

    /// Current ordering.
    ///
    /// Mutated in place by drag-and-drop; the delegate is fired with a
    /// snapshot of the new ordering each time a drop is accepted.
    private(set) var disks: [StorageDisk]

    private let instance: VMInstance
    private let fileMonitor: AttachmentFileMonitor

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// `true` once `viewWillDisappear` has fired.
    ///
    /// Checked by the re-arming `withObservationTracking` closure below
    /// to break the recursion the moment the sheet starts dismissing —
    /// without this, the closure keeps re-registering for the lifetime
    /// of `self`.
    private var hasDisappeared = false

    // MARK: - Layout constants

    private static let sheetWidth: CGFloat = 480
    private static let sheetHeight: CGFloat = 320
    private static let padding: CGFloat = 16
    private static let rowHeight: CGFloat = 44
    /// Custom pasteboard type used to identify our row drags.
    ///
    /// Scoped to this controller (`forLocal: true`) so other apps can't
    /// accept the drag and so we don't accept foreign drags.
    private static let rowPasteboardType = NSPasteboard.PasteboardType(
        "app.kernova.storagedisk-row"
    )

    init(
        disks: [StorageDisk],
        instance: VMInstance,
        fileMonitor: AttachmentFileMonitor
    ) {
        self.disks = disks
        self.instance = instance
        self.fileMonitor = fileMonitor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StorageDiskReorderSheetContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let divider1 = makeHorizontalSeparator()
        let body = makeTableSection()
        let divider2 = makeHorizontalSeparator()
        let footer = makeFooter()

        [header, divider1, body, divider2, footer].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeFileMonitor()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        hasDisappeared = true
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "Boot Order")
        title.font = .preferredFont(forTextStyle: .headline)
        title.isSelectable = false

        let info = InfoButtonView()
        info.configure(
            label: "Boot Order",
            paragraphs: [
                .body(
                    "Drag rows to set the order in which the guest sees its storage. Position 1 boots first on EFI guests; on macOS and Linux Kernel boot, the order also determines guest device enumeration (for example, /dev/vda, /dev/vdb)."
                )
            ]
        )

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, info, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])
        return container
    }

    // MARK: - Table

    private func makeTableSection() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("disk"))
        column.resizingMask = .autoresizingMask

        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowHeight = Self.rowHeight
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = []
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.rowPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

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

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let done = NSButton(
            title: "Done", target: self, action: #selector(doneTapped(_:))
        )
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"  // Return = default action

        let stack = NSStackView(views: [spacer, done])
        stack.orientation = .horizontal
        stack.spacing = Spacing.standard
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])
        return container
    }

    // MARK: - Actions

    @objc private func doneTapped(_: NSButton) {
        delegate?.storageDiskReorderSheetDidDismiss(self)
    }

    // MARK: - File-monitor observation

    /// Re-arming `withObservationTracking` subscription on `fileMonitor.existsByPath`.
    ///
    /// When a file's existence flag flips, the table reloads so the
    /// missing-file affordance updates without the user having to close
    /// and re-open the sheet. The re-arming chain terminates when
    /// `hasDisappeared` flips in `viewWillDisappear` — without that
    /// guard the closure keeps registering for the lifetime of `self`,
    /// even after the sheet has been dismissed.
    private func observeFileMonitor() {
        if hasDisappeared { return }
        withObservationTracking { [fileMonitor] in
            _ = fileMonitor.existsByPath
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.hasDisappeared else { return }
                self.tableView.reloadData()
                self.observeFileMonitor()
            }
        }
    }

    // MARK: - Helpers

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

// MARK: - NSTableViewDataSource

extension StorageDiskReorderSheetContentViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        disks.count
    }

    /// Encodes the source row index onto the pasteboard so
    /// `acceptDrop` can resolve it back to the original disk.
    func tableView(
        _ tableView: NSTableView, pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowPasteboardType)
        return item
    }

    /// Only accept drops *between* rows (`.above`), never on top of a
    /// row — there's no nested concept here, just a flat reordered list.
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard
            let item = info.draggingPasteboard.pasteboardItems?.first,
            let payload = item.string(forType: Self.rowPasteboardType),
            let sourceRow = Int(payload)
        else { return false }
        return performReorder(sourceRow: sourceRow, proposedRow: row)
    }

    /// Pure reorder primitive — separated from `acceptDrop` so tests can
    /// exercise the index math (and the delegate firing) without
    /// constructing an `NSDraggingInfo` mock.
    ///
    /// - Parameters:
    ///   - sourceRow: Index of the row being dragged.
    ///   - proposedRow: Insertion index AppKit reports as the drop
    ///     target (the gap *above* row N, so `proposedRow == disks.count`
    ///     means "drop at the very end").
    /// - Returns: `true` when the reorder happened; `false` when the
    ///   inputs were invalid or the drop was a no-op (drag to its own
    ///   slot).
    @discardableResult
    func performReorder(sourceRow: Int, proposedRow: Int) -> Bool {
        guard sourceRow >= 0, sourceRow < disks.count else { return false }
        // When dragging a row downward, removing it first shifts every
        // subsequent index by -1 so the effective target is
        // `proposedRow - 1`. Dragging upward leaves the target unchanged.
        let target = sourceRow < proposedRow ? proposedRow - 1 : proposedRow
        if target == sourceRow { return false }
        let moved = disks.remove(at: sourceRow)
        disks.insert(moved, at: target)
        tableView.reloadData()
        if target < tableView.numberOfRows {
            tableView.selectRowIndexes([target], byExtendingSelection: false)
        }
        delegate?.storageDiskReorderSheet(self, didReorderTo: disks)
        return true
    }
}

// MARK: - NSTableViewDelegate

extension StorageDiskReorderSheetContentViewController: NSTableViewDelegate {
    /// Builds the per-row cell view.
    ///
    /// Reuses dequeued ``StorageDiskReorderRowCellView`` instances when
    /// available; creates a fresh one otherwise.
    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("StorageDiskReorderRow")
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: nil)
            as? StorageDiskReorderRowCellView ?? StorageDiskReorderRowCellView()
        cell.identifier = identifier

        let disk = disks[row]
        let isMissing = !disk.isInternal && !fileMonitor.exists(disk.path)
        cell.configure(
            disk: disk,
            instance: instance,
            isMissing: isMissing
        )
        return cell
    }
}

/// Per-row cell for the Boot Order table.
///
/// Lays out the AppKit ``AttachmentIconButton`` (which shows a red
/// warning glyph + popover when the backing file is missing) next to a
/// vertical text stack with the disk's display label and a path-or-stats
/// subtitle. Built fresh in code rather than via a XIB — composition is
/// small enough that an Auto Layout setup in `init` is the cleanest
/// expression of the layout.
@MainActor
final class StorageDiskReorderRowCellView: NSTableCellView {
    private let iconButton = AttachmentIconButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel: NSTextField

    init() {
        subtitleLabel = makeAttachmentSubtitleLabel(path: "", isMissing: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Typography.body
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isSelectable = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [iconButton, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StorageDiskReorderRowCellView does not support NSCoder")
    }

    /// Apply the disk's icon + label + subtitle to the cell.
    ///
    /// Updates the icon, label, and subtitle in place so the missing-file
    /// color/weight updates as the live ``AttachmentFileMonitor`` flips
    /// a path's `exists` state — without tearing down the reused cell's views.
    func configure(disk: StorageDisk, instance: VMInstance, isMissing: Bool) {
        iconButton.configure(
            systemName: diskIconSystemName(for: disk),
            missingPath: isMissing ? disk.path : nil
        )
        titleLabel.stringValue = disk.label
        // Reads in-bundle sizes off-main; the `identifier` token guards against
        // this reused cell being rebound to a different disk mid-read. Painted
        // without the fade — a drag-drop reorder triggers `reloadData()`, and a
        // fade on every rebound cell reads as a flicker on each reorder.
        populateDiskSubtitle(
            subtitleLabel, for: disk, bundleLayout: instance.bundleLayout, isMissing: isMissing,
            animated: false)
    }
}
