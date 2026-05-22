import AppKit

/// Modal sheet for reordering a VM's storage disks via drag-and-drop.
///
/// Replaces the SwiftUI `StorageDiskReorderSheet`. Uses `NSTableView` with
/// internal drag-reorder via a custom pasteboard type so the row order
/// translates back to the configuration through the same write closure as
/// the original.
@MainActor
final class StorageDiskReorderWindowController: NSWindowController {
    private static let pasteboardType = NSPasteboard.PasteboardType("com.kernova.storagedisk.reorder")

    private let instance: VMInstance
    private let fileMonitor: AttachmentFileMonitor
    private let readDisks: () -> [StorageDisk]
    private let writeDisks: ([StorageDisk]) -> Void
    private var disks: [StorageDisk]
    private let tableView = NSTableView()
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        instance: VMInstance,
        fileMonitor: AttachmentFileMonitor,
        readDisks: @escaping () -> [StorageDisk],
        writeDisks: @escaping ([StorageDisk]) -> Void
    ) {
        self.instance = instance
        self.fileMonitor = fileMonitor
        self.readDisks = readDisks
        self.writeDisks = writeDisks
        self.disks = readDisks()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Boot Order"

        super.init(window: window)
        window.contentViewController = NSViewController().apply { vc in
            vc.view = buildRootView()
        }

        tableView.delegate = self
        tableView.dataSource = self
        tableView.registerForDraggedTypes([Self.pasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StorageDiskReorderWindowController does not support NSCoder")
    }

    @discardableResult
    func runSheet(on parent: NSWindow) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            guard let window = self.window else {
                cont.resume()
                return
            }
            parent.beginSheet(window) { [weak self] _ in
                self?.continuation?.resume()
                self?.continuation = nil
            }
        }
    }

    // MARK: - View construction

    private func buildRootView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Boot Order")
        header.font = .preferredFont(forTextStyle: .headline)
        header.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Drag rows to set the order in which the guest sees its storage. "
                + "Position 1 boots first on EFI guests; on macOS and Linux Kernel boot, "
                + "the order also determines guest device enumeration."
        )
        subtitle.font = .preferredFont(forTextStyle: .caption1)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 0

        let headerStack = NSStackView(views: [header, subtitle])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let topDivider = NSBox(); topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false

        // Configure table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("disk"))
        column.title = "Disk"
        column.minWidth = 360
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnResizing = false
        tableView.allowsColumnSelection = false
        tableView.rowHeight = 40
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .inset
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let bottomDivider = NSBox(); bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        doneButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, doneButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerStack)
        root.addSubview(topDivider)
        root.addSubview(scroll)
        root.addSubview(bottomDivider)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: root.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            topDivider.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            bottomDivider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            root.widthAnchor.constraint(equalToConstant: 520),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        return root
    }

    // MARK: - Actions

    @objc private func done(_ sender: Any?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window, returnCode: .OK)
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension StorageDiskReorderWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        disks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < disks.count else { return nil }
        return makeRowView(for: disks[row])
    }

    private func makeRowView(for disk: StorageDisk) -> NSView {
        let dragHandle = NSImageView(
            image: .systemSymbol("line.3.horizontal", accessibilityDescription: ""))
        dragHandle.contentTintColor = .secondaryLabelColor

        let iconButton = AttachmentIconButton()
        let isMissing = !disk.isInternal && !fileMonitor.exists(disk.path)
        iconButton.configure(
            systemName: diskIconSystemName(for: disk),
            missingPath: isMissing ? disk.path : nil
        )

        let label = NSTextField(labelWithString: disk.label)
        label.font = .preferredFont(forTextStyle: .body)

        let subtitle = makeAttachmentSubtitleLabel(
            path: diskSubtitle(for: disk, in: instance),
            isMissing: isMissing
        )

        let textStack = NSStackView(views: [label, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [dragHandle, iconButton, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        return row
    }

    // MARK: - Drag

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: Self.pasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row destination: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard
            let item = info.draggingPasteboard.pasteboardItems?.first,
            let sourceString = item.string(forType: Self.pasteboardType),
            let source = Int(sourceString),
            source >= 0, source < disks.count
        else { return false }

        let target = destination > source ? destination - 1 : destination
        let moved = disks.remove(at: source)
        disks.insert(moved, at: target)
        tableView.reloadData()
        writeDisks(disks)
        return true
    }
}

private extension NSViewController {
    /// Tiny helper to apply configuration in an expression position.
    func apply(_ block: (NSViewController) -> Void) -> NSViewController {
        block(self)
        return self
    }
}
