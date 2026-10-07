import AppKit
import KernovaKit
import KernovaLogging
import UniformTypeIdentifiers

/// Pure-AppKit sidebar: a source-list `NSOutlineView` listing virtual machines
/// under collapsible sections — each smart group, then "Virtual Machines".
///
/// The outline view's items are the nodes of a ``SidebarTree`` built from
/// ``SidebarLayout/project(entries:options:retaining:smartGroups:context:)``,
/// updated by inserts and removes; per-row live updates are owned by each
/// ``SidebarVMRowCellView``. Selection is a two-way binding to
/// `viewModel.selection`, idempotent in both directions; row reorder, smart
/// group reorder and Finder-bundle import ride the outline view's
/// drag-and-drop, distinguished by drag source and pasteboard type.
@MainActor
final class SidebarViewController: NSViewController {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "SidebarViewController")

    private let viewModel: VMLibraryViewModel
    private var preferences: AppPreferences { viewModel.preferences }
    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let tree = SidebarTree()

    private var modelObservation: ObservationLoop?

    /// The library's ``VMLibrary/revealCount`` the last sync applied; a sync
    /// finding it moved opens what hides the selected row.
    private var appliedRevealCount = 0

    /// The row currently hosting an inline-rename field editor, so the rename
    /// loop doesn't restart an in-flight edit.
    private var editingRow: SidebarRow?

    /// Builds each section header's menu; a pick runs its command.
    private lazy var viewMenu = SidebarViewMenu(
        networkTitle: { [weak self] network in
            network.choice?.title(
                attachable: true, interfaces: [], networks: self?.viewModel.networks.networks ?? [])
                ?? NetworkModeChoice.unlistedNetworkTitle
        },
        perform: { [weak self] command in self?.perform(command) })

    private static let rowPasteboardType = NSPasteboard.PasteboardType("app.kernova.sidebar-vm-row")
    private static let smartGroupPasteboardType = NSPasteboard.PasteboardType("app.kernova.sidebar-smart-group")
    private static let groupCellID = NSUserInterfaceItemIdentifier("SidebarGroupHeaderCell")
    private static let placeholderCellID = NSUserInterfaceItemIdentifier("SidebarPlaceholderCell")
    private static let mainColumnID = NSUserInterfaceItemIdentifier("main")
    private static let leafRowHeight: CGFloat = 42
    private static let groupRowHeight: CGFloat = 24

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarViewController does not support NSCoder")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()

        let column = NSTableColumn(identifier: Self.mainColumnID)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 4
        outlineView.floatsGroupRows = false
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.beginRenameForRow = { [weak self] row in
            guard let self,
                let instance = (self.outlineView.item(atRow: row) as? SidebarRow)?.entry.vm,
                self.viewModel.capabilities.isAvailable(.rename, on: instance)
            else { return }
            self.viewModel.renameVMInSidebar(instance)
        }
        outlineView.registerForDraggedTypes([
            Self.rowPasteboardType,
            Self.smartGroupPasteboardType,
            .fileURL,
            NSPasteboard.PasteboardType(UTType.kernovaVM.identifier),
        ])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.contextMenuForRow = { [weak self] row in
            self?.contextMenu(forRow: row)
        }

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // Overlay whatever the scroll-bar setting: the divider snap fits the
        // outline to the longest name (`widthToFitLongestRow()`), and a legacy
        // scroller, shown only while the list overflows, takes its gutter out of
        // that width whenever it appears, truncating the name the snap fitted.
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Leave `automaticallyAdjustsContentInsets` at its default (true): in a
        // full-size-content window with a unified toolbar, it insets the outline
        // content below the toolbar instead of letting rows scroll under it.
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        appliedRevealCount = viewModel.revealCount
        let changes = tree.update(to: viewModel.sidebarLayout)
        outlineView.reloadData()
        expandCreated(changes.created)
    }

    /// Opens each created section as last saved; a group header lists its rows
    /// beside it and opens nothing.
    private func expandCreated(_ nodes: [SidebarNode]) {
        for case let section as SidebarSection in nodes {
            applySavedExpansion(to: section)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if modelObservation == nil {
            modelObservation = observeRecurring(
                track: { [weak self] in
                    guard let self else { return }
                    // Everything `sync()` reads from the model. Computing the
                    // layout reads exactly what it depends on: the entries,
                    // the options, and each value the active filter, sort and
                    // grouping read of every VM.
                    _ = self.viewModel.sidebarLayout
                    _ = self.viewModel.selection
                    _ = self.viewModel.revealCount
                    _ = self.viewModel.activeRename
                },
                apply: { [weak self] in self?.sync() }
            )
        }
        // Everything the observation watches can change while it is torn down,
        // and re-arming it fires nothing — a `withObservationTracking`
        // registration only reports changes made *after* it.
        sync()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        modelObservation?.cancel()
        modelObservation = nil
        outlineView.cancelPendingRename()
    }

    // MARK: - Model → view

    /// Brings the outline view to the model: the projection first, so the
    /// selection and the rename resolve against the tree that lists the
    /// library's current entries.
    ///
    /// The one entry point to the selection and rename passes. Every step is
    /// idempotent, so a pass the outline view's own callbacks start in the
    /// middle of another changes nothing the outer pass then undoes.
    private func sync() {
        applyProjection()
        let reveals = viewModel.revealCount
        let revealing = reveals != appliedRevealCount
        appliedRevealCount = reveals
        applySelectionFromModel(revealing: revealing)
        applyRenameState()
    }

    /// Brings the tree to the library's current projection and applies the
    /// change as inserts, removes and per-row reloads, so a row the change
    /// leaves alone keeps its view — and any rename open in it.
    ///
    /// The model's selection then moves onto the new rows
    /// (``VMLibrary/reconcileSelection(with:)``): a selected VM the change hid
    /// is no longer selected.
    private func applyProjection() {
        let layout = viewModel.sidebarLayout
        let changes = tree.update(to: layout)
        defer {
            viewModel.reconcileSelection(with: layout)
            refreshSectionHeaders()
        }
        guard !changes.isEmpty else { return }
        // Commit a rename whose row the change takes down before the update,
        // through the label's own commit path (resigning first responder).
        // AppKit also ends the edit when it removes the view (observed macOS
        // 27.0), but nothing documents that, and it would run the commit inside
        // the update. The session ends with its view, so a row the change
        // reinserts comes back closed.
        if let editingRow, changes.detaches(editingRow) {
            view.window?.makeFirstResponder(outlineView)
            self.editingRow = nil
        }
        outlineView.beginUpdates()
        // Each parent's removals index its previous children, its moves the
        // children as each finds them, and its insertions its current ones,
        // which is the order NSOutlineView takes them in; parents' offsets are
        // independent of each other.
        for change in changes.children {
            if !change.removed.isEmpty {
                outlineView.removeItems(at: change.removed, inParent: change.parent, withAnimation: [])
            }
            for move in change.moves {
                outlineView.moveItem(at: move.from, inParent: change.parent, to: move.to, inParent: change.parent)
            }
            if !change.inserted.isEmpty {
                outlineView.insertItems(at: change.inserted, inParent: change.parent, withAnimation: [])
            }
        }
        outlineView.endUpdates()
        for node in changes.reloaded { outlineView.reloadItem(node) }
        expandCreated(changes.created)
    }

    /// Selects the row the model's selection lands on, and moves the model's
    /// selection onto that row when it landed by fallback.
    ///
    /// Only a reveal (`revealing`) opens the collapsed sections hiding the
    /// row. Any other selection — a restored one included — leaves the
    /// user's collapsed sections as they are, and the outline shows no
    /// selected row while the model keeps the selection.
    private func applySelectionFromModel(revealing: Bool) {
        guard let selection = viewModel.selection, let node = tree.row(resolving: selection) else {
            if outlineView.selectedRow != -1 { outlineView.deselectAll(nil) }
            return
        }
        if node.key != selection { viewModel.selection = node.key }
        guard let row = revealing ? revealedRow(of: node) : shownRow(of: node) else {
            if outlineView.selectedRow != -1 { outlineView.deselectAll(nil) }
            return
        }
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        // NSOutlineView doesn't auto-scroll programmatic selection into view, so a
        // created/cloned/imported VM's row could land off-screen.
        outlineView.scrollRowToVisible(row)
    }

    /// `node`'s outline row, `nil` while a collapsed ancestor hides it.
    private func shownRow(of node: SidebarNode) -> Int? {
        let row = outlineView.row(forItem: node)
        return row >= 0 ? row : nil
    }

    /// `node`'s outline row, expanding its collapsed ancestors first; `nil` when
    /// the outline view does not list it.
    private func revealedRow(of node: SidebarNode) -> Int? {
        var ancestors: [SidebarNode] = []
        var candidate = node.parent
        while let ancestor = candidate {
            ancestors.append(ancestor)
            candidate = ancestor.parent
        }
        for ancestor in ancestors.reversed() where !outlineView.isItemExpanded(ancestor) {
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? row : nil
    }

    // MARK: - Inline rename

    /// The row a sidebar rename of the entry `id` is open in: the row already
    /// editing it while the tree still lists that row, else the selected row
    /// when it shows that entry, else the entry's library row.
    private func renameRow(for id: UUID) -> SidebarRow? {
        if let editingRow, editingRow.key.entryID == id, tree.row(for: editingRow.key) === editingRow {
            return editingRow
        }
        let selected = viewModel.selection.flatMap { tree.row(resolving: $0) }
        let row = selected?.key.entryID == id ? selected : tree.row(resolving: .library(id))
        return row?.entry.vm == nil ? nil : row
    }

    private func applyRenameState() {
        guard case .sidebar(let id)? = viewModel.activeRename, let node = renameRow(for: id) else {
            endActiveEditingIfNeeded()
            return
        }
        guard editingRow !== node else { return }
        // Moving the rename to a different row: end the previous session first,
        // committing its in-flight text — the switch path below otherwise never
        // tears the old row down.
        endActiveEditingIfNeeded()

        guard let row = revealedRow(of: node) else { return }

        editingRow = node

        // Rename implies selection.
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        if viewModel.selection != node.key { viewModel.selection = node.key }

        // Make the row visible before editing so `makeIfNecessary` returns the
        // on-screen cell rather than fabricating a detached one.
        outlineView.scrollRowToVisible(row)
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? SidebarVMRowCellView
        {
            cell.beginRename()
        }
        setRowUnemphasized(true, atRow: row)
    }

    private func endActiveEditingIfNeeded() {
        guard let node = editingRow else { return }
        editingRow = nil
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarVMRowCellView
        {
            cell.endRename()
        }
        // Settle the selection emphasis back to its natural state now that the
        // edit is torn down.
        (outlineView.rowView(atRow: row, makeIfNecessary: false) as? SidebarTableRowView)?
            .settleEmphasis()
    }

    /// Flips the row's selection between unemphasized grey and emphasized blue.
    ///
    /// Grey while the name is being edited, so the white edit box stands out.
    private func setRowUnemphasized(_ unemphasized: Bool, atRow row: Int) {
        let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false)
        (rowView as? SidebarTableRowView)?.rendersUnemphasized = unemphasized
    }

    /// Settles the edited row's selection emphasis after an edit ends, deferred
    /// to the next main-actor turn so any commit-click has moved the first
    /// responder before we read it.
    ///
    /// With `grabbingFocus` (a keyboard Return/Escape) focus is first returned to
    /// the sidebar. The field editor resigns first responder *after* the
    /// end-editing notification fires, so this must run on a later turn or it is
    /// overridden. A click-commit passes false and lets focus follow the click.
    private func restoreSidebarFocus(grabbingFocus: Bool = true) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if grabbingFocus { self.view.window?.makeFirstResponder(self.outlineView) }
            let row = self.outlineView.selectedRow
            // A row that has since started its own rename must stay unemphasized
            // while its edit box is up — don't settle it back to blue.
            if let editingRow = self.editingRow, self.outlineView.item(atRow: row) as? SidebarRow === editingRow {
                return
            }
            (self.outlineView.rowView(atRow: row, makeIfNecessary: false)
                as? SidebarTableRowView)?.settleEmphasis()
        }
    }

    // MARK: - Double-click

    @objc private func rowDoubleClicked(_: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let instance = (outlineView.item(atRow: row) as? SidebarRow)?.entry.vm
        else { return }
        let capabilities = viewModel.capabilities
        if capabilities.isAvailable(.start, on: instance) {
            Task { await viewModel.start(instance) }
        } else if capabilities.isAvailable(.resume, on: instance) {
            Task { await viewModel.resume(instance) }
        }
    }

    // MARK: - Expansion persistence

    /// Collapses `section` when it was last saved collapsed, and expands it
    /// otherwise — so a section new to this sidebar, a smart group just
    /// created among them, opens expanded.
    private func applySavedExpansion(to section: SidebarSection) {
        if preferences.collapsedSidebarSections.contains(section.id.rawValue) {
            outlineView.collapseItem(section)
        } else {
            outlineView.expandItem(section)
        }
    }

    /// Saves `item`'s expansion when it is a section, keeping only sections
    /// the sidebar lists.
    ///
    /// One section at a time: the sections a load creates open one after
    /// another, so a snapshot of them all mid-way would save the ones not yet
    /// opened as collapsed.
    private func persistExpansion(of item: Any?, expanded: Bool) {
        guard let section = item as? SidebarSection else { return }
        var collapsed = Set(preferences.collapsedSidebarSections)
        if expanded {
            collapsed.remove(section.id.rawValue)
        } else {
            collapsed.insert(section.id.rawValue)
        }
        preferences.collapsedSidebarSections = tree.sections.map(\.id.rawValue).filter(collapsed.contains)
    }

    // MARK: - Content-fit width

    /// The sidebar width at which the longest VM name is fully visible, or `nil`
    /// when there's nothing to measure — no row laid out under an expanded
    /// section.
    ///
    /// Drives the split-view divider's Finder-style snap-to-fit.
    func widthToFitLongestRow() -> CGFloat? {
        let outlineWidth = outlineView.bounds.width
        let widest = (0..<outlineView.numberOfRows).compactMap { row -> CGFloat? in
            guard let node = outlineView.item(atRow: row) as? SidebarRow else { return nil }
            // Everything the row's level costs besides its cell: the
            // indentation before it and the inset the outline view keeps after
            // it, which a row under a group header has too.
            let cell = outlineView.frameOfCell(atColumn: 0, row: row)
            let chrome = cell.minX + max(outlineWidth - cell.maxX, 0)
            return chrome + contentWidth(of: node.entry)
        }.max()
        // The width the *outline view* must have — the split-view divider sits a
        // few points outboard of this, which the snap controller converts.
        return widest.map { $0 + Self.fitBreathingRoom }
    }

    private func contentWidth(of entry: LibraryEntry) -> CGFloat {
        let detail = rowDetail { entry }()
        guard case .vm(let instance) = entry else {
            return SidebarVMRowCellView.contentWidth(
                forName: entry.name, detail: detail, showsAgentAccessory: false,
                showsEphemeralAccessory: false)
        }
        return SidebarVMRowCellView.contentWidth(
            forName: instance.name, detail: detail,
            showsAgentAccessory: SidebarVMRowCellView.visibleAgentStatus(
                for: instance, installPromptDisabled: viewModel.agentInstallPromptDisabled) != nil,
            showsEphemeralAccessory: instance.hostState.ephemeralModeEnabled
        )
    }

    /// Trailing slack added to the snap-to-fit width so the longest name isn't
    /// flush against the sidebar edge.
    private static let fitBreathingRoom: CGFloat = 12

    /// The outline view's current width, so the snap controller can derive the
    /// divider-to-outline offset from live geometry.
    var currentOutlineWidth: CGFloat { outlineView.bounds.width }

    // MARK: - Helpers

    /// The row an internal drag carries, while the tree still lists it.
    private func draggedRow(_ info: NSDraggingInfo) -> SidebarRow? {
        guard let data = info.draggingPasteboard.pasteboardItems?.first?.data(forType: Self.rowPasteboardType),
            let key = try? JSONDecoder().decode(SidebarRowKey.self, from: data)
        else { return nil }
        return tree.row(for: key)
    }

    /// The smart group an internal drag of its header carries.
    private func draggedSmartGroup(_ info: NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.smartGroupPasteboardType)
            .flatMap(UUID.init(uuidString:))
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return tree.sections.count }
        return (item as? SidebarNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return tree.sections[index] }
        guard let node = item as? SidebarNode else {
            preconditionFailure("Only a SidebarNode reports children")
        }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    // MARK: Drag source

    func outlineView(
        _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        // A smart group's header drags to reorder the smart groups.
        if let section = item as? SidebarSection {
            guard let id = section.id.smartGroupID else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(id.uuidString, forType: Self.smartGroupPasteboardType)
            return pbItem
        }
        // Arrivals are not draggable: their place is settled once they are VMs.
        // Rows drag only under the manual sort — the one order a drop changes.
        guard viewModel.sidebarOptions.sort == .manual,
            let row = item as? SidebarRow, row.entry.vm != nil,
            let data = try? JSONEncoder().encode(row.key)
        else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setData(data, forType: Self.rowPasteboardType)
        return pbItem
    }

    // MARK: Drop

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if info.draggingSource as? NSOutlineView === outlineView, draggedSmartGroup(info) != nil {
            outlineView.setDropItem(nil, dropChildIndex: smartGroupDropIndex(proposedItem: item, childIndex: index))
            return .move
        }
        if info.draggingSource as? NSOutlineView === outlineView {
            // Internal reorder — constrained to the gaps of the dragged row's
            // own list: its group's rows, which follow its header.
            guard let source = draggedRow(info), let parent = source.parent,
                let list = Self.list(of: source)
            else { return [] }
            let target: Int
            switch item {
            case let row as SidebarRow:
                guard row.parent === parent, row.key.group == source.key.group else { return [] }
                target = parent.children.firstIndex { $0 === row } ?? list.upperBound
            case let node as SidebarNode:
                guard node === parent else { return [] }
                if index == NSOutlineViewDropOnItemIndex {
                    target = list.upperBound
                } else {
                    guard (list.lowerBound...list.upperBound).contains(index) else { return [] }
                    target = index
                }
            default:
                // Outside every section. AppKit proposes the root with
                // `NSOutlineViewDropOnItemIndex` for the empty space below the
                // last row, which is the dragged row's list's end; a root gap
                // above its section is that list's top.
                let section = tree.sections.firstIndex { $0.id == source.key.section } ?? 0
                target =
                    index == NSOutlineViewDropOnItemIndex || index > section
                    ? list.upperBound : list.lowerBound
            }
            outlineView.setDropItem(parent, dropChildIndex: target)
            return .move
        }
        if info.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        return []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        if info.draggingSource as? NSOutlineView === outlineView, let moved = draggedSmartGroup(info) {
            return acceptSmartGroupMove(moved, toSectionIndex: index)
        }
        if info.draggingSource as? NSOutlineView === outlineView {
            return acceptReorder(info: info, parent: item as? SidebarNode, childIndex: index)
        }
        return acceptImport(info: info)
    }

    /// The root offset a dragged smart group lands at, among the smart group
    /// sections that lead the sidebar: before the section the drag is over —
    /// after it when over the section's own rows — or after the last smart
    /// group when below them.
    private func smartGroupDropIndex(proposedItem item: Any?, childIndex index: Int) -> Int {
        let smartCount = tree.sections.prefix { $0.id.smartGroupID != nil }.count
        let target: Int
        switch item {
        case nil:
            target = index == NSOutlineViewDropOnItemIndex ? smartCount : index
        case let section as SidebarSection:
            let offset = tree.sections.firstIndex { $0 === section } ?? smartCount
            target = index == NSOutlineViewDropOnItemIndex || index == 0 ? offset : offset + 1
        case let node as SidebarNode:
            var top = node
            while let parent = top.parent { top = parent }
            target = (tree.sections.firstIndex { $0 === top } ?? smartCount) + 1
        default:
            target = smartCount
        }
        return min(max(target, 0), smartCount)
    }

    /// Moves the dragged smart group to the root offset it was dropped at.
    private func acceptSmartGroupMove(_ moved: UUID, toSectionIndex index: Int) -> Bool {
        let smartSections = tree.sections.prefix { $0.id.smartGroupID != nil }
        let successor = index < smartSections.count ? smartSections[index].id.smartGroupID : nil
        guard successor != moved else { return false }
        attempt("Couldn\u{2019}t Move the Smart Group") { try viewModel.moveSmartGroup(moved, before: successor) }
        return true
    }

    /// Moves the dragged row's entry in the manual order to just before the
    /// sibling it was dropped above — or after the last sibling — whatever
    /// entries the section leaves out.
    private func acceptReorder(info: NSDraggingInfo, parent: SidebarNode?, childIndex: Int) -> Bool {
        guard let source = draggedRow(info), let parent, source.parent === parent,
            let list = Self.list(of: source)
        else {
            return false
        }
        let visible = parent.children[list].compactMap { ($0 as? SidebarRow)?.key.entryID }
        let order = viewModel.entries.map(\.id)
        let gap = childIndex == NSOutlineViewDropOnItemIndex ? list.upperBound : childIndex
        let index = min(max(gap, list.lowerBound), list.upperBound) - list.lowerBound
        guard let sourceIndex = order.firstIndex(of: source.key.entryID),
            let offset = SidebarLayout.manualOrderOffset(
                moving: source.key.entryID, toVisibleIndex: index, amongVisible: visible, in: order)
        else { return false }
        viewModel.moveEntries(fromOffsets: IndexSet(integer: sourceIndex), toOffset: offset)
        return true
    }

    /// The offsets in `row`'s parent of the list `row` reorders within: the
    /// run of rows of its group, which a group header — listed beside its
    /// rows — bounds.
    static func list(of row: SidebarRow) -> Range<Int>? {
        guard let siblings = row.parent?.children,
            let at = siblings.firstIndex(where: { $0 === row })
        else { return nil }
        func inList(_ node: SidebarNode) -> Bool {
            (node as? SidebarRow)?.key.group == row.key.group
        }
        var lower = at
        while lower > 0, inList(siblings[lower - 1]) { lower -= 1 }
        var upper = at + 1
        while upper < siblings.count, inList(siblings[upper]) { upper += 1 }
        return lower..<upper
    }

    /// Filters the drop to `.kernova` bundles and imports the batch.
    private func acceptImport(info: NSDraggingInfo) -> Bool {
        guard
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
        else { return false }

        return viewModel.importVMs(fromDroppedURLs: urls)
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarRow
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is SidebarRow ? Self.leafRowHeight : Self.groupRowHeight
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        switch item {
        case let section as SidebarSection: headerCell(for: section)
        case let header as SidebarGroupHeader: headerCell(title: header.title)
        case let placeholder as SidebarPlaceholder: placeholderCell(placeholder.text)
        case let row as SidebarRow:
            switch row.entry {
            case .arriving(let arrival): arrivalCell(arrival)
            case .vm(let instance): vmCell(instance, isRenaming: editingRow === row)
            }
        default: nil
        }
    }

    private func headerCell(for section: SidebarSection) -> NSView {
        let cell = headerCell(title: section.title)
        configureHeader(cell, for: section)
        return cell
    }

    private func headerCell(title: String) -> SidebarGroupHeaderCellView {
        let cell =
            outlineView.makeView(withIdentifier: Self.groupCellID, owner: nil)
            as? SidebarGroupHeaderCellView
            ?? {
                let made = SidebarGroupHeaderCellView()
                made.identifier = Self.groupCellID
                return made
            }()
        cell.configure(title: title)
        return cell
    }

    private func placeholderCell(_ text: String) -> NSView {
        let cell =
            outlineView.makeView(withIdentifier: Self.placeholderCellID, owner: nil) as? NSTableCellView
            ?? {
                let made = NSTableCellView()
                made.identifier = Self.placeholderCellID
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingTail
                made.addSubview(label)
                made.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: made.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: made.trailingAnchor),
                    label.centerYAnchor.constraint(equalTo: made.centerYAnchor),
                ])
                return made
            }()
        cell.textField?.stringValue = text
        return cell
    }

    private func arrivalCell(_ arrival: VMArrival) -> NSView {
        let cell =
            outlineView.makeView(
                withIdentifier: SidebarArrivalRowCellView.reuseIdentifier, owner: nil)
            as? SidebarArrivalRowCellView ?? SidebarArrivalRowCellView()
        cell.configure(
            arrival: arrival, detail: rowDetail { [weak arrival] in arrival.map(LibraryEntry.arriving) })
        return cell
    }

    /// A row's detail line, read live by its cell: the sort key's value while
    /// Show Details is on, `nil` otherwise. `entry` captures its object
    /// weakly, since the cell keeps the closure.
    private func rowDetail(_ entry: @escaping () -> LibraryEntry?) -> () -> String? {
        { [weak self] in
            guard let self, let entry = entry() else { return nil }
            let options = self.viewModel.sidebarOptions
            return options.showsDetails ? options.sort.detail(for: entry) : nil
        }
    }

    private func vmCell(_ instance: VMInstance, isRenaming: Bool) -> NSView {
        let cell =
            outlineView.makeView(withIdentifier: SidebarVMRowCellView.reuseIdentifier, owner: nil)
            as? SidebarVMRowCellView ?? SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: isRenaming,
            installPromptDisabled: { [weak self] in
                self?.viewModel.agentInstallPromptDisabled ?? false
            },
            // Capture `instance` weakly: the cell stores these closures, so a
            // strong capture would keep a deleted VM alive until the cell is
            // recycled.
            isBusy: { [weak instance] in
                instance?.phase.operation != nil
            },
            detail: rowDetail { [weak instance] in instance.map(LibraryEntry.vm) },
            onCommitRename: { [weak self, weak instance] newName, endedByReturn in
                guard let self, let instance else { return }
                self.viewModel.commitRename(for: instance, newName: newName, from: .sidebar)
                // Return keeps focus in the sidebar; a click-commit lets focus
                // follow the click.
                self.restoreSidebarFocus(grabbingFocus: endedByReturn)
            },
            onCancelRename: { [weak self, weak instance] in
                guard let self, let instance else { return }
                self.viewModel.cancelRename(for: instance, from: .sidebar)
                // Escape returns focus to the sidebar (and the blue selection).
                self.restoreSidebarFocus()
            },
            onAgentDiskControl: { [weak self, weak instance] in
                guard let self, let instance else { return }
                self.viewModel.toggleGuestAgentDisk(on: instance)
            },
            onDismissAgentNudge: { [weak self, weak instance] in
                guard let self, let instance else { return }
                self.viewModel.dismissAgentInstallNudge(for: instance)
            }
        )
        return cell
    }

    /// Provides the custom ``SidebarTableRowView`` so a row renders its selection
    /// unemphasized (grey) while its name is being edited.
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let reused = outlineView.makeView(
            withIdentifier: SidebarTableRowView.reuseID, owner: self) as? SidebarTableRowView
        {
            return reused
        }
        let rowView = SidebarTableRowView()
        rowView.identifier = SidebarTableRowView.reuseID
        return rowView
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Any selection change invalidates a pending slow-second-click rename
        // (which is only armed on a click of the already-selected row).
        outlineView.cancelPendingRename()
        // Idempotent: a selection the model→view pass makes names the row the
        // model already resolves to, or the fallback row it then writes anyway.
        let row = outlineView.selectedRow
        if row >= 0, let node = outlineView.item(atRow: row) as? SidebarRow {
            if viewModel.selection != node.key { viewModel.selection = node.key }
        } else if let id = viewModel.selectedID,
            !viewModel.entries.contains(where: { $0.id == id })
        {
            // Empty selection clears the model only when the selected VM is
            // truly gone — a transient -1 from collapsing the group, or from an
            // update removing and reinserting the row, must not wipe a
            // still-valid selection.
            viewModel.selection = nil
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        persistExpansion(of: notification.userInfo?["NSObject"], expanded: true)
        // Restore the highlight for a still-selected row that was hidden while
        // its group was collapsed.
        sync()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        persistExpansion(of: notification.userInfo?["NSObject"], expanded: false)
    }
}

// MARK: - Filter, sort and group

extension SidebarViewController {
    /// The library as the filter menu counts it.
    private func viewMenuValues() -> [SidebarViewMenu.Value] {
        let context = viewModel.sidebarContext
        return viewModel.entries.map { entry in
            let subject = context.subject(of: entry)
            return SidebarViewMenu.Value(
                subject: subject,
                networkTitle: SidebarLayout.networkTitle(
                    subject.network, of: entry.configuration, context: context))
        }
    }

    /// The menu `section`'s header button and a right-click on the header
    /// open: the library's filter, group and sort menu, or a smart group's
    /// own; `nil` for a section with neither.
    func viewMenu(for section: SidebarSectionID) -> NSMenu? {
        if section == .library {
            return viewMenu.menu(options: viewModel.sidebarOptions, values: viewMenuValues())
        }
        guard let id = section.smartGroupID, let group = viewModel.smartGroups.first(where: { $0.id == id })
        else { return nil }
        return viewMenu.menu(smartGroup: group, values: viewMenuValues())
    }

    private func popUpViewMenu(for section: SidebarSectionID, from button: NSButton) {
        viewMenu(for: section)?.popUp(
            positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    /// What `section`'s header shows beside its title; `nil` for a section
    /// with no menu.
    private func filtering(for section: SidebarSection) -> SidebarGroupHeaderCellView.Filtering? {
        // The counts the projection the tree lists computed, so they change
        // exactly when the rows do.
        let counts = tree.layout.sections.first { $0.id == section.id }?.filterCounts
        if let id = section.id.smartGroupID {
            guard let group = viewModel.smartGroups.first(where: { $0.id == id }) else { return nil }
            return SidebarGroupHeaderCellView.Filtering(
                countText: counts.map { "\($0.shown)" }, isActive: false,
                activeDescription: viewMenu.activeFilterDescription(filter: group.filter, values: viewMenuValues()),
                buttonLabel: SidebarViewMenu.smartGroupAccessibilityLabel)
        }
        guard section.id == .library else { return nil }
        guard let counts else {
            return SidebarGroupHeaderCellView.Filtering(countText: nil, isActive: false, activeDescription: nil)
        }
        return SidebarGroupHeaderCellView.Filtering(
            countText: "\(counts.shown) of \(counts.total)", isActive: true,
            activeDescription: viewMenu.activeFilterDescription(
                filter: viewModel.sidebarOptions.filter, values: viewMenuValues()))
    }

    /// Shows `section`'s title, count and menu button in `cell`.
    private func configureHeader(_ cell: SidebarGroupHeaderCellView, for section: SidebarSection) {
        let filtering = filtering(for: section)
        let id = section.id
        cell.configure(
            title: section.title, filtering: filtering,
            onFilterButton: filtering == nil
                ? nil : { [weak self] button in self?.popUpViewMenu(for: id, from: button) })
    }

    /// Re-renders each section header the outline view has a view for.
    private func refreshSectionHeaders() {
        for section in tree.sections {
            let row = outlineView.row(forItem: section)
            guard row >= 0,
                let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? SidebarGroupHeaderCellView
            else { continue }
            configureHeader(cell, for: section)
        }
    }

    // MARK: Commands

    /// Runs what a section menu's pick asks for.
    private func perform(_ command: SidebarViewMenu.Command) {
        switch command {
        case .setOptions(let options):
            viewModel.sidebarOptions = options
        case .saveAsSmartGroup:
            presentSaveAsSmartGroup()
        case .setSmartGroupFilter(let id, let filter):
            attempt("Couldn\u{2019}t Change the Smart Group") { try viewModel.setFilter(filter, ofSmartGroup: id) }
        case .renameSmartGroup(let id):
            presentRenameSmartGroup(id)
        case .deleteSmartGroup(let id):
            attempt("Couldn\u{2019}t Delete the Smart Group") { try viewModel.deleteSmartGroup(id) }
        }
    }

    /// Asks for a name to save the library's filter under as a smart group,
    /// starting from `name` — a suggestion from the filter when `nil`. A name
    /// the library refuses brings the sheet back with that name in it.
    private func presentSaveAsSmartGroup(name: String? = nil) {
        guard let window = view.window else { return }
        let filter = viewModel.sidebarOptions.filter
        let values = viewMenuValues()
        presentSheetAlert(
            SmartGroupNameSheet.newSmartGroup(
                suggestedName: name
                    ?? viewModel.unusedSmartGroupName(from: viewMenu.suggestedName(for: filter, values: values)),
                conditions: viewMenu.conditions(of: filter, values: values)
            ) { [weak self] typed in
                self?.attempt(
                    "Couldn\u{2019}t Create the Smart Group",
                    retry: { [weak self] in self?.presentSaveAsSmartGroup(name: typed) }
                ) { try self?.viewModel.saveSidebarFilterAsSmartGroup(named: typed) }
            },
            in: window)
    }

    /// Asks for a new name for the smart group `id` identifies, starting from
    /// `name` — its current one when `nil`. A name the library refuses brings
    /// the sheet back with that name in it.
    private func presentRenameSmartGroup(_ id: UUID, name: String? = nil) {
        guard let window = view.window, let group = viewModel.smartGroups.first(where: { $0.id == id }) else {
            return
        }
        presentSheetAlert(
            SmartGroupNameSheet.rename(currentName: name ?? group.name) { [weak self] typed in
                self?.attempt(
                    "Couldn\u{2019}t Rename the Smart Group",
                    retry: { [weak self] in self?.presentRenameSmartGroup(id, name: typed) }
                ) { try self?.viewModel.renameSmartGroup(id, to: typed) }
            },
            in: window)
    }

    /// Runs `change`, showing what it was refused with under `title`, then
    /// `retry` once that alert is dismissed.
    private func attempt(_ title: String, retry: (() -> Void)? = nil, _ change: () throws -> Void) {
        do {
            try change()
        } catch {
            let message = error.localizedDescription
            #log(Self.logger, .notice, "\(title, privacy: .public): \(message, privacy: .public)")
            guard let window = view.window else { return }
            presentSheetAlert(.acknowledgement(title: title, message: message), in: window, completion: retry)
        }
    }
}

// MARK: - Context menu

extension SidebarViewController {
    /// Builds the right-click menu for the clicked row, selecting it first
    /// (matching standard source-list behavior); a section's header opens the
    /// menu its button does.
    func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0 else { return nil }
        if let section = outlineView.item(atRow: row) as? SidebarSection {
            return viewMenu(for: section.id)
        }
        guard let node = outlineView.item(atRow: row) as? SidebarRow else { return nil }

        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        if viewModel.selection != node.key { viewModel.selection = node.key }

        return switch node.entry {
        case .arriving(let arrival): buildContextMenu(for: arrival)
        case .vm(let instance): buildContextMenu(for: instance)
        }
    }

    /// An arrival offers only the cancel of its create, clone or import.
    func buildContextMenu(for arrival: VMArrival) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let cancel = NSMenuItem(
            title: arrival.kind.cancelLabel, action: #selector(menuCancelPreparing(_:)),
            keyEquivalent: "")
        cancel.target = self
        cancel.representedObject = arrival
        menu.addItem(cancel)
        return menu
    }

    func buildContextMenu(for instance: VMInstance) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let capabilities = viewModel.capabilities

        // Lifecycle
        var startItem: NSMenuItem?
        if capabilities.isApplicable(.start, to: instance) {
            if capabilities.isApplicable(.startInRecovery, to: instance)
                && !preferences.alwaysShowAdvancedOptions
            {
                // With an isAlternate pair at the very top, hiding the primary on
                // ⌥-hold collapses the visible top to index 1 while AppKit still
                // anchors the menu window on index 0's original coordinates, so every
                // row shifts down by one item's height. This zero-height item at
                // index 0 gives the "Start" pair a mid-menu pair's positioning.
                let dummy = NSMenuItem()
                dummy.view = NSView(frame: .zero)
                menu.addItem(dummy)
            }
            let start = item(instance.startAction.label, #selector(menuStart(_:)), instance)
            start.isEnabled = capabilities.isAvailable(.start, on: instance)
            menu.addItem(start)
            startItem = start
        }
        if capabilities.isApplicable(.startInRecovery, to: instance) {
            // An Option-alternate of "Start", or a plain always-visible item when
            // "Always show advanced options" is on. Recovery implies `.stopped`,
            // so "Start" was just added and immediately precedes this one —
            // required for alternate pairing.
            let recovery = item("Start in Recovery Mode…", #selector(menuStartRecovery(_:)), instance)
            recovery.isEnabled = capabilities.isAvailable(.startInRecovery, on: instance)
            if !preferences.alwaysShowAdvancedOptions {
                // Keyless Option-reveal: both items have an empty key equivalent, so the
                // primary's modifier mask must be cleared to [] (its default is [.command])
                // for AppKit to collapse the pair into ONE row. Otherwise the pair doesn't
                // merge and the menu gains a row — and shifts — when Option is held.
                startItem?.keyEquivalentModifierMask = []
                recovery.keyEquivalentModifierMask = [.option]
                recovery.isAlternate = true
            }
            menu.addItem(recovery)
        }
        if capabilities.isApplicable(.pause, to: instance) {
            let pause = item("Pause", #selector(menuPause(_:)), instance)
            pause.isEnabled = capabilities.isAvailable(.pause, on: instance)
            menu.addItem(pause)
        }
        if capabilities.isApplicable(.resume, to: instance) {
            let resume = item("Resume", #selector(menuResume(_:)), instance)
            resume.isEnabled = capabilities.isAvailable(.resume, on: instance)
            menu.addItem(resume)
        }
        let canStop = capabilities.isApplicable(.stop, to: instance)
        let discardsSavedState = capabilities.isApplicable(.discardSavedState, to: instance)
        let stopAction = capabilities.stopAction(for: instance)
        if canStop {
            let stop = item(stopAction.menuTitle, #selector(menuStop(_:)), instance)
            stop.isEnabled = capabilities.isAvailable(.stop, on: instance)
            menu.addItem(stop)
            // An Option-alternate of "Stop". No zero-height anchor is needed: when
            // a graceful stop is offered, a Pause or Resume item always precedes
            // "Stop", so the pair is never at index 0 and the menu can't shift on
            // ⌥-press.
            let forceStop = item("Force Stop…", #selector(menuForceStop(_:)), instance)
            forceStop.isEnabled = capabilities.isAvailable(.forceStop, on: instance)
            if !preferences.alwaysShowAdvancedOptions {
                stop.keyEquivalentModifierMask = []
                forceStop.keyEquivalentModifierMask = [.option]
                forceStop.isAlternate = true
            }
            menu.addItem(forceStop)
        }
        if discardsSavedState {
            // Listed whatever its state, disabled when there is nothing behind
            // it: an Ephemeral VM already resting on its baseline would revert
            // to what it is already holding, and the greying is what tells the
            // user so. The stop slot's own selector, so the title and the
            // command come from `stopAction` together.
            let discard = item(stopAction.menuTitle, #selector(menuStop(_:)), instance)
            discard.isEnabled = capabilities.isStopActionAvailable(on: instance)
            menu.addItem(discard)
        }

        // State
        let canSuspend = capabilities.isApplicable(.suspend, to: instance)
        let canTakeSnapshot = capabilities.isApplicable(.takeSnapshot, to: instance)
        let canRevert = capabilities.isApplicable(.revertToSnapshot, to: instance)
        if canSuspend || canTakeSnapshot || canRevert {
            menu.addItem(.separator())
        }
        if canSuspend {
            let suspend = item("Suspend", #selector(menuSuspend(_:)), instance)
            suspend.isEnabled = capabilities.isAvailable(.suspend, on: instance)
            menu.addItem(suspend)
        }
        if canTakeSnapshot {
            let takeSnapshot = item(
                "Take Snapshot\u{2026}", #selector(menuTakeSnapshot(_:)), instance)
            takeSnapshot.isEnabled = capabilities.isAvailable(.takeSnapshot, on: instance)
            menu.addItem(takeSnapshot)
        }
        if canRevert {
            let revert = NSMenuItem(title: SnapshotRevertMenu.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: SnapshotRevertMenu.title)
            SnapshotRevertMenu.rebuild(
                submenu, for: instance,
                isEnabled: capabilities.isAvailable(.revertToSnapshot, on: instance),
                target: self, action: #selector(menuRevertToSnapshot(_:)))
            revert.submenu = submenu
            menu.addItem(revert)
        }

        // Display
        if capabilities.isApplicable(.togglePopOut, to: instance) {
            menu.addItem(.separator())
            menu.addItem(
                responderItem(
                    instance.isDisplayDetached ? "Pop In Display" : "Pop Out Display",
                    #selector(AppDelegate.togglePopOut(_:)), instance
                ))
            menu.addItem(
                responderItem(
                    instance.isInFullscreen ? "Exit Fullscreen Display" : "Fullscreen Display",
                    #selector(AppDelegate.toggleFullscreen(_:)), instance
                ))
        }

        menu.addItem(.separator())

        // Management
        let rename = item("Rename", #selector(menuRename(_:)), instance)
        rename.isEnabled = capabilities.isAvailable(.rename, on: instance)
        menu.addItem(rename)

        let cloneItems = preferences.cloneMenuItems(for: instance.configuration)
        let clone = item(cloneItems.primary.title, #selector(menuClone(_:)), instance)
        clone.isEnabled = capabilities.isAvailable(.clone, on: instance)
        menu.addItem(clone)
        // An ⌥-alternate of Clone making the other outcome, where the VM offers
        // one. Mid-menu (Rename precedes), so no anchor item is needed.
        if let alternate = cloneItems.alternate {
            let cloneAlternate = item(alternate.title, #selector(menuCloneAlternate(_:)), instance)
            cloneAlternate.isEnabled = clone.isEnabled
            if !preferences.alwaysShowAdvancedOptions {
                clone.keyEquivalentModifierMask = []
                cloneAlternate.keyEquivalentModifierMask = [.option]
                cloneAlternate.isAlternate = true
            }
            menu.addItem(cloneAlternate)
        }

        menu.addItem(item("Show in Finder", #selector(menuShowInFinder(_:)), instance))

        menu.addItem(.separator())

        // "Move to Trash…" gathers input (which externals to delete), so the
        // ellipsis is correct here.
        let trash = item("Move to Trash…", #selector(menuMoveToTrash(_:)), instance)
        trash.isEnabled = capabilities.isAvailable(.delete, on: instance)
        menu.addItem(trash)
        // An ⌥-alternate of "Move to Trash…". This pair sits at the menu's end, so
        // collapsing the primary can't shift the menu; no anchor item is needed.
        let deleteImmediately = item("Delete Immediately…", #selector(menuDeleteImmediately(_:)), instance)
        deleteImmediately.isEnabled = trash.isEnabled
        if !preferences.alwaysShowAdvancedOptions {
            trash.keyEquivalentModifierMask = []
            deleteImmediately.keyEquivalentModifierMask = [.option]
            deleteImmediately.isAlternate = true
        }
        menu.addItem(deleteImmediately)

        return menu
    }

    private func item(_ title: String, _ action: Selector, _ instance: VMInstance) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = instance
        menuItem.isEnabled = true
        return menuItem
    }

    /// A menu item dispatched down the responder chain (target `nil`) so the
    /// app delegate handles it — used for the display pop-out/fullscreen toggles.
    ///
    /// Carries the clicked row's VM so the delegate acts on it: its own
    /// key-window rule would otherwise name whichever VM's display window is in
    /// front.
    private func responderItem(_ title: String, _ action: Selector, _ instance: VMInstance)
        -> NSMenuItem
    {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = nil
        menuItem.representedObject = instance
        menuItem.isEnabled = true
        return menuItem
    }

    // MARK: Actions

    @objc private func menuStart(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        Task { await viewModel.start(instance) }
    }

    @objc private func menuStartRecovery(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.requestStartInRecovery(instance)
    }

    @objc private func menuPause(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        Task { await viewModel.pause(instance) }
    }

    @objc private func menuResume(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        Task { await viewModel.resume(instance) }
    }

    @objc private func menuStop(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        Task { await viewModel.stop(instance) }
    }

    @objc private func menuForceStop(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.requestForceStop(instance)
    }

    @objc private func menuSuspend(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        Task { await viewModel.save(instance) }
    }

    @objc private func menuTakeSnapshot(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.requestTakeSnapshot(instance)
    }

    @objc private func menuRevertToSnapshot(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? SnapshotMenuRef else { return }
        viewModel.requestRevert(ref.instance, to: ref.snapshot)
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.renameVMInSidebar(instance)
    }

    @objc private func menuClone(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.cloneVM(instance)
    }

    @objc private func menuCloneAlternate(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.cloneVMAsAlternate(instance)
    }

    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
    }

    @objc private func menuMoveToTrash(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.requestDelete(instance)
    }

    @objc private func menuDeleteImmediately(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.requestDelete(instance, permanently: true)
    }

    @objc private func menuCancelPreparing(_ sender: NSMenuItem) {
        guard let arrival = sender.representedObject as? VMArrival else { return }
        viewModel.requestCancelPreparing(arrival)
    }
}

// MARK: - Outline view subclass

/// `NSOutlineView` subclass that routes right-clicks to a controller-supplied
/// menu builder, and begins a rename on a Finder-style slow second click of an
/// already-selected row's name.
final class SidebarOutlineView: NSOutlineView {
    var contextMenuForRow: ((Int) -> NSMenu?)?
    /// Called with the row to rename on a slow second click of a selected row.
    var beginRenameForRow: ((Int) -> Void)?

    /// The item armed for a slow-second-click rename.
    ///
    /// Captured by identity (not row index) so a list mutation during the
    /// double-click delay can't retarget the rename to whatever VM now sits at the
    /// old index. Weak so a removed VM simply drops the pending rename.
    private weak var pendingRenameItem: AnyObject?

    /// Every group row's Show/Hide control the outline view has made,
    /// captured where AppKit asks for one by
    /// `NSOutlineView.showHideButtonIdentifier`.
    private let showHideButtons = NSHashTable<NSView>.weakObjects()

    override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?
    ) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.showHideButtonIdentifier, let view {
            showHideButtons.add(view)
        }
        return view
    }

    /// The Show/Hide control `rowView` holds, `nil` when it holds none.
    func showHideButton(in rowView: NSView) -> NSView? {
        showHideButtons.allObjects.first { $0.isDescendant(of: rowView) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuForRow?(row(at: point))
    }

    override func mouseDown(with event: NSEvent) {
        let startPoint = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: startPoint)

        // A double-click is the Start/Resume action: drop any pending rename and
        // let the base class route the event to `doubleAction`.
        if event.clickCount >= 2 {
            cancelPendingRename()
            super.mouseDown(with: event)
            return
        }

        // Capture selection *before* the click changes it: renaming requires the
        // row to have already been selected (the second click of click-to-select
        // then click-to-rename).
        let wasSelected = clickedRow >= 0 && selectedRow == clickedRow
        let overName = isClick(startPoint, overNameOfRow: clickedRow)

        super.mouseDown(with: event)  // selection + drag tracking, returns on mouse-up

        // Skip if the gesture became a drag (row reorder) rather than a click.
        let endPoint =
            window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? startPoint
        let moved = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y) > 4

        guard wasSelected, overName, !moved, clickedRow >= 0, selectedRow == clickedRow,
            let clickedItem = item(atRow: clickedRow) as AnyObject?
        else {
            return
        }
        // Defer past the double-click window so a follow-up double-click (Start)
        // cancels the rename instead of racing it.
        pendingRenameItem = clickedItem
        perform(
            #selector(firePendingRename), with: nil, afterDelay: NSEvent.doubleClickInterval)
    }

    private func isClick(_ point: NSPoint, overNameOfRow row: Int) -> Bool {
        guard row >= 0,
            let cell = view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarVMRowCellView
        else { return false }
        return cell.isPointOverName(cell.convert(point, from: self))
    }

    @objc private func firePendingRename() {
        guard let item = pendingRenameItem else { return }
        pendingRenameItem = nil
        // Re-resolve the item's *current* row and only rename if it's still the
        // selected row, so a mutation during the delay can't rename the wrong VM.
        let row = row(forItem: item)
        guard row >= 0, row == selectedRow else { return }
        beginRenameForRow?(row)
    }

    /// Drops any armed slow-second-click rename, so a stale arm can't fire later.
    func cancelPendingRename() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self as Any, selector: #selector(firePendingRename), object: nil)
        pendingRenameItem = nil
    }
}

// MARK: - Row view subclass

/// Source-list row view that renders its selection *unemphasized* — the lighter
/// "selected but not focused" grey — while the row's name is being edited, so
/// the white rounded edit box stands out against it.
///
/// Without this the selection stays emphasized (accent blue) during editing:
/// `NSTableRowView`'s emphasis reports `true` whenever the table *contains* the
/// first responder, and the field editor is a descendant.
final class SidebarTableRowView: NSTableRowView {
    static let reuseID = NSUserInterfaceItemIdentifier("SidebarTableRow")

    /// Set while the row's name is being edited.
    ///
    /// Setting the stored `isEmphasized` to `false` rebuilds the source-list
    /// selection material as grey now — a bare `needsDisplay` doesn't refresh it;
    /// the getter override then keeps it grey even if the table re-reads it.
    var rendersUnemphasized = false {
        didSet {
            guard rendersUnemphasized != oldValue, rendersUnemphasized else { return }
            super.isEmphasized = false
        }
    }

    override var isEmphasized: Bool {
        get { rendersUnemphasized ? false : super.isEmphasized }
        set { super.isEmphasized = newValue }
    }

    /// Rebuilds the cached selection material to the row's **natural** emphasis
    /// after an edit ends: blue when the table is the focused first responder in a
    /// key window, grey otherwise.
    ///
    /// The source-list material only rebuilds on a *changed* `isEmphasized` set —
    /// during the edit the stored value was forced `false` — so the setter is
    /// toggled to force the rebuild.
    func settleEmphasis() {
        rendersUnemphasized = false
        let emphasized = naturalEmphasis
        super.isEmphasized = !emphasized
        super.isEmphasized = emphasized
    }

    /// `true` when this row's enclosing table view is (or contains) the window's
    /// first responder in a key window — i.e. the selection should read as the
    /// active, emphasized blue.
    private var naturalEmphasis: Bool {
        guard let window, window.isKeyWindow, let table = enclosingTableView,
            let responder = window.firstResponder as? NSView
        else { return false }
        return responder.isDescendant(of: table)
    }

    private var enclosingTableView: NSTableView? {
        var candidate = superview
        while let view = candidate {
            if let table = view as? NSTableView { return table }
            candidate = view.superview
        }
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        rendersUnemphasized = false
    }

    /// Tells a header cell how far the Show/Hide control in this row reaches
    /// into it, once both have their frames.
    override func layout() {
        super.layout()
        guard let header = view(atColumn: 0) as? SidebarGroupHeaderCellView else { return }
        let showHide = (enclosingTableView as? SidebarOutlineView)?.showHideButton(in: self)
        header.trailingReserve =
            showHide.map { max(header.bounds.maxX - header.convert($0.bounds, from: $0).minX, 0) } ?? 0
    }
}
