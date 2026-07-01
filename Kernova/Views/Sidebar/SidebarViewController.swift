import AppKit
import UniformTypeIdentifiers

/// Pure-AppKit sidebar: a source-list `NSOutlineView` listing virtual machines
/// under a collapsible "Virtual Machines" group.
///
/// Replaces the former SwiftUI `SidebarView`/`VMRowView`. The outline view is a
/// two-level tree of ``SidebarSection`` group rows over `VMInstance` leaf rows;
/// today there is one section, but the structure makes adding a second group
/// (e.g. "Containers") a localized change. State flows from the `@Observable`
/// ``VMLibraryViewModel`` through three ``ObservationLoop``s (instances,
/// selection, active rename); per-row live updates are owned by each
/// ``SidebarVMRowCellView``. Selection is a guarded two-way binding to
/// `viewModel.selectedID`; reorder and Finder-bundle import ride the outline
/// view's drag-and-drop, distinguished by drag source.
@MainActor
final class SidebarViewController: NSViewController {
    private let viewModel: VMLibraryViewModel
    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let sections: [SidebarSection] = [.virtualMachines]

    private var instancesObservation: ObservationLoop?
    private var selectionObservation: ObservationLoop?
    private var renameObservation: ObservationLoop?

    /// Guards the model→view selection apply so the synchronous
    /// `outlineViewSelectionDidChange` callback doesn't write back into the
    /// model and ping-pong.
    private var isUpdatingSelectionFromModel = false

    /// The VM whose row currently hosts an inline-rename field editor, so the
    /// rename loop doesn't restart an in-flight edit.
    private var editingItemID: UUID?

    private static let rowPasteboardType = NSPasteboard.PasteboardType("app.kernova.sidebar-vm-row")
    private static let groupCellID = NSUserInterfaceItemIdentifier("SidebarGroupHeaderCell")
    private static let mainColumnID = NSUserInterfaceItemIdentifier("main")
    private static let expandedSectionsKey = "KernovaSidebarExpandedSections"
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
                let instance = self.outlineView.item(atRow: row) as? VMInstance,
                instance.status.canRename
            else { return }
            self.viewModel.renameVMInSidebar(instance)
        }
        outlineView.registerForDraggedTypes([
            Self.rowPasteboardType,
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
        // Overlay scrollers float over content and auto-fade, rather than a
        // legacy scroller permanently reserving a strip on the right edge.
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Leave `automaticallyAdjustsContentInsets` at its default (true): in a
        // full-size-content window with a unified toolbar, this insets the
        // outline content below the toolbar/title bar instead of letting rows
        // scroll up underneath it.
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
        outlineView.reloadData()
        restoreExpansion()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startObservations()
        applySelectionFromModel()
        applyRenameState()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopObservations()
        outlineView.cancelPendingRename()
    }

    // MARK: - Observation

    private func startObservations() {
        if instancesObservation == nil {
            instancesObservation = observeRecurring(
                track: { [weak self] in _ = self?.viewModel.instances.map(\.id) },
                apply: { [weak self] in self?.reloadInstances() }
            )
        }
        if selectionObservation == nil {
            selectionObservation = observeRecurring(
                track: { [weak self] in _ = self?.viewModel.selectedID },
                apply: { [weak self] in self?.applySelectionFromModel() }
            )
        }
        if renameObservation == nil {
            renameObservation = observeRecurring(
                track: { [weak self] in _ = self?.viewModel.activeRename },
                apply: { [weak self] in self?.applyRenameState() }
            )
        }
    }

    private func stopObservations() {
        instancesObservation?.cancel()
        instancesObservation = nil
        selectionObservation?.cancel()
        selectionObservation = nil
        renameObservation?.cancel()
        renameObservation = nil
    }

    private func reloadInstances() {
        // Commit any in-flight rename first: a reload tears the field editor
        // down underneath the user, which would otherwise drop keyboard focus
        // and race a partial-text commit. Resigning first responder ends
        // editing cleanly through the normal commit path.
        if editingItemID != nil {
            view.window?.makeFirstResponder(outlineView)
        }
        // A reload reshuffles rows, so drop any armed slow-second-click rename.
        outlineView.cancelPendingRename()
        // Guard the reload so any selection churn it triggers isn't written
        // back into the model (every other selection-mutating call guards too).
        isUpdatingSelectionFromModel = true
        outlineView.reloadData()
        isUpdatingSelectionFromModel = false
        applySelectionFromModel()
        applyRenameState()
    }

    // MARK: - Selection (model ↔ view)

    private func applySelectionFromModel() {
        isUpdatingSelectionFromModel = true
        defer { isUpdatingSelectionFromModel = false }

        guard let id = viewModel.selectedID,
            let instance = viewModel.instances.first(where: { $0.id == id })
        else {
            if outlineView.selectedRow != -1 { outlineView.deselectAll(nil) }
            return
        }

        var row = outlineView.row(forItem: instance)
        if row < 0, let section = sectionContaining(instance) {
            outlineView.expandItem(section)
            row = outlineView.row(forItem: instance)
        }
        guard row >= 0 else { return }
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        // NSOutlineView doesn't auto-scroll programmatic selection into view
        // (SwiftUI's List did), so a created/cloned/imported VM's row could land
        // off-screen.
        outlineView.scrollRowToVisible(row)
    }

    // MARK: - Inline rename

    private func applyRenameState() {
        guard case .sidebar(let id)? = viewModel.activeRename,
            let instance = viewModel.instances.first(where: { $0.id == id })
        else {
            endActiveEditingIfNeeded()
            return
        }
        guard editingItemID != id else { return }
        // Moving the rename to a different row: end the previous session first
        // (committing its in-flight text and settling its row's emphasis) —
        // the switch path below otherwise never tears the old row down.
        endActiveEditingIfNeeded()

        if outlineView.row(forItem: instance) < 0, let section = sectionContaining(instance) {
            outlineView.expandItem(section)
        }
        let row = outlineView.row(forItem: instance)
        guard row >= 0 else { return }

        editingItemID = id

        // Rename implies selection; select synchronously without re-entering
        // the model→view path.
        isUpdatingSelectionFromModel = true
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        isUpdatingSelectionFromModel = false
        if viewModel.selectedID != id { viewModel.selectedID = id }

        // Make the row visible before editing so `makeIfNecessary` returns the
        // on-screen cell rather than fabricating a detached one.
        outlineView.scrollRowToVisible(row)
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? SidebarVMRowCellView
        {
            cell.setRenaming(true)
        }
        setRowUnemphasized(true, atRow: row)
    }

    private func endActiveEditingIfNeeded() {
        guard let id = editingItemID else { return }
        editingItemID = nil
        guard let instance = viewModel.instances.first(where: { $0.id == id }) else { return }
        let row = outlineView.row(forItem: instance)
        guard row >= 0 else { return }
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarVMRowCellView
        {
            // Commit a live session before flipping the cell's rename flag:
            // `setRenaming(false)` alone gates off `controlTextDidEndEditing`
            // without resigning the editor, so a later resign would silently
            // drop the typed text (which ordering the observation loops fire
            // in is unspecified).
            cell.commitActiveRenameSession()
            cell.setRenaming(false)
        }
        // Settle the selection emphasis back to its natural state (blue if the
        // sidebar still holds focus, grey otherwise) now that the edit is torn
        // down. The keyboard/click commit paths additionally re-settle deferred
        // via `restoreSidebarFocus`, once any commit-click has moved focus.
        (outlineView.rowView(atRow: row, makeIfNecessary: false) as? SidebarTableRowView)?
            .settleEmphasis()
    }

    /// Flips the row's selection between unemphasized grey and emphasized blue.
    ///
    /// Grey while the name is being edited (so the white edit box stands out),
    /// blue otherwise. The table won't change this on its own: the field editor is
    /// a descendant, so from the table's perspective the selection's emphasis
    /// never changed.
    private func setRowUnemphasized(_ unemphasized: Bool, atRow row: Int) {
        let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false)
        (rowView as? SidebarTableRowView)?.rendersUnemphasized = unemphasized
    }

    /// Settles the edited row's selection emphasis after an edit ends, deferred
    /// to the next main-actor turn so any commit-click has moved the first
    /// responder before we read it.
    ///
    /// When `grabbingFocus` is true (a keyboard Return/Escape) focus is first
    /// returned to the sidebar, so the row reads as the active blue selection —
    /// the field editor resigns first responder *after* the end-editing
    /// notification fires, so this must run on a later turn or it'd be overridden.
    /// A click-commit passes false and lets focus follow the click: the row then
    /// settles to blue (focus stayed in the sidebar) or grey (focus left) on its
    /// own.
    private func restoreSidebarFocus(grabbingFocus: Bool = true) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if grabbingFocus { self.view.window?.makeFirstResponder(self.outlineView) }
            let row = self.outlineView.selectedRow
            // A row that has since started its own rename must stay
            // unemphasized (grey) while its edit box is up — don't settle it
            // back to blue (the rename-switch handoff lands here after the
            // previous row's commit).
            if let id = self.editingItemID,
                let instance = self.outlineView.item(atRow: row) as? VMInstance,
                instance.id == id
            {
                return
            }
            (self.outlineView.rowView(atRow: row, makeIfNecessary: false)
                as? SidebarTableRowView)?.settleEmphasis()
        }
    }

    // MARK: - Double-click

    @objc private func rowDoubleClicked(_: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0,
            let instance = outlineView.item(atRow: row) as? VMInstance,
            !instance.isPreparing
        else { return }
        if instance.status.canStart {
            Task { await viewModel.start(instance) }
        } else if instance.status.canResume {
            Task { await viewModel.resume(instance) }
        }
    }

    // MARK: - Expansion persistence

    private func restoreExpansion() {
        let saved = UserDefaults.standard.array(forKey: Self.expandedSectionsKey) as? [String]
        let expanded = saved.map(Set.init)
        for section in sections {
            // Default to expanded when there's no saved preference yet.
            if expanded?.contains(section.id) ?? true {
                outlineView.expandItem(section)
            } else {
                outlineView.collapseItem(section)
            }
        }
    }

    private func persistExpansion() {
        let expandedIDs = sections.filter { outlineView.isItemExpanded($0) }.map(\.id)
        UserDefaults.standard.set(expandedIDs, forKey: Self.expandedSectionsKey)
    }

    // MARK: - Content-fit width

    /// The sidebar width at which the longest VM name is fully visible (no
    /// truncation), or `nil` when there's nothing to measure — an empty list or
    /// a collapsed group, in which case no leaf row is laid out to read the
    /// indentation from.
    ///
    /// Drives the split-view divider's Finder-style snap-to-fit. The width is
    /// the outline view's per-row indentation (group disclosure + level indent,
    /// read from a real leaf cell's frame) plus the widest row's content width.
    func widthToFitLongestRow() -> CGFloat? {
        let instances = viewModel.instances
        guard !instances.isEmpty else { return nil }

        guard
            let firstLeafRow = (0..<outlineView.numberOfRows).first(where: {
                outlineView.item(atRow: $0) is VMInstance
            })
        else { return nil }
        let indentation = outlineView.frameOfCell(atColumn: 0, row: firstLeafRow).minX

        let widestContent =
            instances.map { instance in
                SidebarVMRowCellView.contentWidth(
                    forName: instance.name,
                    showsAgentAccessory: SidebarVMRowCellView.visibleAgentStatus(for: instance) != nil
                )
            }.max() ?? 0

        // The width the *outline view* must have for the longest name to fit,
        // plus breathing room so the snapped fit leaves a comfortable gap after
        // the name (Finder-style) rather than seating it flush against the edge.
        // The split-view divider sits a few points outboard of this (divider
        // chrome), so the snap controller converts to a divider position.
        return indentation + widestContent + Self.fitBreathingRoom
    }

    /// Trailing slack added to the snap-to-fit width so the longest name isn't
    /// flush against the sidebar edge.
    private static let fitBreathingRoom: CGFloat = 12

    /// The outline view's current width — paired with `widthToFitLongestRow()`
    /// so the snap controller can derive the divider-to-outline offset from
    /// live geometry.
    var currentOutlineWidth: CGFloat { outlineView.bounds.width }

    // MARK: - Helpers

    private func sectionContaining(_ instance: VMInstance) -> SidebarSection? {
        sections.first { children(of: $0).contains { $0 === instance } }
    }

    private func children(of section: SidebarSection) -> [VMInstance] {
        section === SidebarSection.virtualMachines ? viewModel.instances : []
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let section = item as? SidebarSection { return children(of: section).count }
        return item == nil ? sections.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? SidebarSection { return children(of: section)[index] }
        return sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarSection
    }

    // MARK: Drag source

    func outlineView(
        _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let instance = item as? VMInstance, !instance.isPreparing else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(instance.id.uuidString, forType: Self.rowPasteboardType)
        return pbItem
    }

    // MARK: Drop

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        let vmSection = SidebarSection.virtualMachines
        if info.draggingSource as? NSOutlineView === outlineView {
            // Internal reorder — constrain to between VM rows.
            let count = children(of: vmSection).count
            var target = index
            if let instance = item as? VMInstance {
                target = children(of: vmSection).firstIndex { $0 === instance } ?? count
            } else if index == NSOutlineViewDropOnItemIndex {
                target = count
            }
            outlineView.setDropItem(vmSection, dropChildIndex: max(0, min(target, count)))
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
        if info.draggingSource as? NSOutlineView === outlineView {
            return acceptReorder(info: info, childIndex: index)
        }
        return acceptImport(info: info)
    }

    private func acceptReorder(info: NSDraggingInfo, childIndex index: Int) -> Bool {
        guard let pbItem = info.draggingPasteboard.pasteboardItems?.first,
            let idString = pbItem.string(forType: Self.rowPasteboardType),
            let id = UUID(uuidString: idString),
            let sourceIndex = viewModel.instances.firstIndex(where: { $0.id == id }),
            let target = Self.reorderTarget(
                sourceIndex: sourceIndex, proposedIndex: index, count: viewModel.instances.count)
        else { return false }
        viewModel.moveVM(fromOffsets: IndexSet(integer: sourceIndex), toOffset: target)
        return true
    }

    /// Maps a drag-drop child index to the `moveVM` `toOffset`, or `nil` for a no-op.
    ///
    /// A no-op is a drop into the row's own gap. A drop "on" the group
    /// (`NSOutlineViewDropOnItemIndex`) appends. `moveVM` delegates to
    /// `Array.move(fromOffsets:toOffset:)`, whose `toOffset` uses the same
    /// between-rows gap convention the outline view reports — so the proposed
    /// index maps through unchanged (no off-by-one).
    static func reorderTarget(sourceIndex: Int, proposedIndex: Int, count: Int) -> Int? {
        let target = proposedIndex == NSOutlineViewDropOnItemIndex ? count : proposedIndex
        guard target != sourceIndex, target != sourceIndex + 1 else { return nil }
        return target
    }

    private func acceptImport(info: NSDraggingInfo) -> Bool {
        guard
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
        else { return false }

        var imported = false
        for url in urls where VMStorageService.isBundleURL(url) {
            viewModel.importVM(from: url)
            imported = true
        }
        return imported
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is SidebarSection)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is SidebarSection ? Self.groupRowHeight : Self.leafRowHeight
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        if let section = item as? SidebarSection {
            let cell =
                outlineView.makeView(withIdentifier: Self.groupCellID, owner: nil)
                as? SidebarGroupHeaderCellView
                ?? {
                    let made = SidebarGroupHeaderCellView()
                    made.identifier = Self.groupCellID
                    return made
                }()
            cell.configure(title: section.title)
            return cell
        }

        guard let instance = item as? VMInstance else { return nil }
        let cell =
            outlineView.makeView(withIdentifier: SidebarVMRowCellView.reuseIdentifier, owner: nil)
            as? SidebarVMRowCellView ?? SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: viewModel.activeRename == .sidebar(instance.id),
            // Capture `instance` weakly: the cell stores these closures, so a
            // strong capture would keep a deleted VM alive until the cell is
            // recycled. A nil instance means the VM is gone — no-op.
            onCommitRename: { [weak self, weak instance] newName, endedByReturn in
                guard let self, let instance else { return }
                self.viewModel.commitRename(for: instance, newName: newName, from: .sidebar)
                // Return keeps focus in the sidebar (the row settles back to the
                // emphasized blue); a click-commit lets focus follow the click and
                // the row settles to blue or grey depending on where it landed.
                self.restoreSidebarFocus(grabbingFocus: endedByReturn)
            },
            onCancelRename: { [weak self, weak instance] in
                guard let self, let instance else { return }
                self.viewModel.cancelRename(for: instance, from: .sidebar)
                // Escape returns focus to the sidebar (and the blue selection).
                self.restoreSidebarFocus()
            },
            onMountAgent: { [weak self, weak instance] in
                guard let self, let instance else { return }
                self.viewModel.mountGuestAgentInstaller(on: instance)
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
        guard !isUpdatingSelectionFromModel else { return }
        let row = outlineView.selectedRow
        if row >= 0, let instance = outlineView.item(atRow: row) as? VMInstance {
            if viewModel.selectedID != instance.id { viewModel.selectedID = instance.id }
        } else if let id = viewModel.selectedID,
            !viewModel.instances.contains(where: { $0.id == id })
        {
            // Empty selection clears the model only when the selected VM is
            // truly gone — a transient -1 from collapsing the group (or an
            // internal reload) must not wipe a still-valid selection.
            viewModel.selectedID = nil
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        persistExpansion()
        // Restore the highlight for a still-selected row that was hidden while
        // its group was collapsed.
        applySelectionFromModel()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        persistExpansion()
    }
}

// MARK: - Context menu

extension SidebarViewController {
    /// Builds the right-click menu for the clicked row, selecting it first
    /// (matching standard source-list behavior).
    func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let instance = outlineView.item(atRow: row) as? VMInstance else { return nil }

        isUpdatingSelectionFromModel = true
        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        isUpdatingSelectionFromModel = false
        if viewModel.selectedID != instance.id { viewModel.selectedID = instance.id }

        return buildContextMenu(for: instance)
    }

    func buildContextMenu(for instance: VMInstance) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if instance.isPreparing {
            if let operation = instance.preparingState?.operation {
                menu.addItem(item(operation.cancelLabel, #selector(menuCancelPreparing(_:)), instance))
            }
            menu.addItem(item("Show in Finder", #selector(menuShowInFinder(_:)), instance))
            return menu
        }

        let status = instance.status

        // Lifecycle
        var startItem: NSMenuItem?
        if status.canStart {
            if instance.canStartInRecovery && !AppPreferences.shared.alwaysShowAdvancedOptions {
                // RATIONALE: Zero-height dummy item at index 0 anchors the context menu so it
                // doesn't jump downward when "Start" collapses into its Recovery alternate on
                // ⌥-hold. This is a known AppKit constraint, not a bug in our pairing:
                //
                // When an isAlternate pair sits at the very top of a context menu, hiding the
                // primary (index 0) on Option-press collapses the visible top down to index 1,
                // but AppKit's menu-positioning engine still anchors the window on index 0's
                // original coordinates — so every visible row shifts down by one item's height.
                //
                // Finder sidesteps this entirely by never placing an alternate pair at the top:
                // its alternates (e.g. Get Info / Show Inspector) live mid-menu, where a static
                // top item ("Open") keeps the layout anchored. We can't do that here — "Start"
                // must stay at the top for UX — so we reproduce Finder's layout stability the
                // standard Cocoa way: a permanent, never-hidden top anchor at index 0 gives the
                // pair below it the same physics as a mid-menu pair, and nothing shifts.
                let dummy = NSMenuItem()
                dummy.view = NSView(frame: .zero)
                menu.addItem(dummy)
            }
            let start = item(instance.startAction.label, #selector(menuStart(_:)), instance)
            menu.addItem(start)
            startItem = start
        }
        if instance.canStartInRecovery {
            // Advanced action: an Option-alternate of "Start" (revealed on ⌥-hold),
            // or a plain always-visible item when "Always show advanced options" is on.
            // `canStartInRecovery` implies `.stopped`, so "Start" was just added and
            // this item immediately precedes this one (required for alternate pairing).
            let recovery = item("Start in Recovery Mode", #selector(menuStartRecovery(_:)), instance)
            if !AppPreferences.shared.alwaysShowAdvancedOptions {
                // Keyless Option-reveal: both items have an empty key equivalent, so the
                // primary's modifier mask must be cleared to [] (its default is [.command])
                // for AppKit to collapse the pair into ONE row. Otherwise [.command] is not
                // a subset of the alternate's [.option], the pair doesn't merge, and the
                // menu gains a row (and shifts position) when Option is held.
                startItem?.keyEquivalentModifierMask = []
                recovery.keyEquivalentModifierMask = [.option]
                recovery.isAlternate = true
            }
            menu.addItem(recovery)
        }
        if status.canPause {
            menu.addItem(item("Pause", #selector(menuPause(_:)), instance))
        }
        if status.canResume {
            menu.addItem(item("Resume", #selector(menuResume(_:)), instance))
        }
        if instance.canStop {
            let stop = item(instance.stopActionMenuTitle, #selector(menuStop(_:)), instance)
            menu.addItem(stop)
            // Advanced action: an Option-alternate of "Stop" (revealed on ⌥-hold),
            // or a plain always-visible item when "Always show advanced options" is on.
            // Unlike the Start/Recovery pair this needs no zero-height top anchor: when
            // `canStop` holds, a Pause or Resume item always precedes "Stop", so the pair
            // is never at index 0 and the menu can't shift downward on ⌥-press. See the
            // Start/Recovery block above for the anchor rationale and the keyless-reveal
            // requirement that the primary's modifier mask be cleared to [].
            let forceStop = item("Force Stop…", #selector(menuForceStop(_:)), instance)
            if !AppPreferences.shared.alwaysShowAdvancedOptions {
                stop.keyEquivalentModifierMask = []
                forceStop.keyEquivalentModifierMask = [.option]
                forceStop.isAlternate = true
            }
            menu.addItem(forceStop)
        }
        if instance.isColdPaused {
            menu.addItem(item(instance.stopActionMenuTitle, #selector(menuForceStop(_:)), instance))
        } else if instance.canForceStop && !instance.canStop {
            // Transient states (starting/saving/restoring) where graceful stop isn't
            // available: there's no "Stop" to pair with, so surface "Force Stop…" plainly.
            menu.addItem(item("Force Stop…", #selector(menuForceStop(_:)), instance))
        }

        // State
        if instance.canSave {
            menu.addItem(.separator())
            menu.addItem(item("Suspend", #selector(menuSuspend(_:)), instance))
        }

        // Display
        if instance.canUseExternalDisplay {
            menu.addItem(.separator())
            menu.addItem(
                responderItem(
                    instance.isInSeparateWindow ? "Pop In Display" : "Pop Out Display",
                    #selector(AppDelegate.togglePopOut(_:))
                ))
            menu.addItem(
                responderItem(
                    instance.isInFullscreen ? "Exit Fullscreen Display" : "Fullscreen Display",
                    #selector(AppDelegate.toggleFullscreen(_:))
                ))
        }

        menu.addItem(.separator())

        // Management
        let rename = item("Rename", #selector(menuRename(_:)), instance)
        rename.isEnabled = status.canRename
        menu.addItem(rename)

        let clone = item("Clone", #selector(menuClone(_:)), instance)
        clone.isEnabled = status.canEditSettings && !viewModel.hasPreparing
        menu.addItem(clone)

        menu.addItem(item("Show in Finder", #selector(menuShowInFinder(_:)), instance))

        menu.addItem(.separator())

        // Destructive — "Move to Trash…" gathers input (which externals to delete), so
        // per the project HIG rule the ellipsis is correct here.
        let trash = item("Move to Trash…", #selector(menuMoveToTrash(_:)), instance)
        trash.isEnabled = status.canEditSettings
        menu.addItem(trash)
        // Advanced destructive: an ⌥-alternate of "Move to Trash…" (revealed on ⌥-hold),
        // or a plain always-visible item when "Always show advanced options" is on. Mirrors
        // the Stop/Force Stop pair above — no zero-height top anchor is needed because this
        // pair sits at the menu's end, so collapsing the primary can't shift the menu.
        let deleteImmediately = item("Delete Immediately…", #selector(menuDeleteImmediately(_:)), instance)
        deleteImmediately.isEnabled = status.canEditSettings
        if !AppPreferences.shared.alwaysShowAdvancedOptions {
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
    private func responderItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = nil
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
        viewModel.confirmStartInRecovery(instance)
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
        viewModel.stop(instance)
    }

    @objc private func menuForceStop(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.confirmForceStop(instance)
    }

    @objc private func menuSuspend(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        Task { await viewModel.save(instance) }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.renameVMInSidebar(instance)
    }

    @objc private func menuClone(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.cloneVM(instance)
    }

    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
    }

    @objc private func menuMoveToTrash(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.confirmDelete(instance)
    }

    @objc private func menuDeleteImmediately(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.confirmDelete(instance, permanently: true)
    }

    @objc private func menuCancelPreparing(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.confirmCancelPreparing(instance)
    }
}

// MARK: - Outline view subclass

/// `NSOutlineView` subclass that routes right-clicks to a controller-supplied
/// menu builder, and begins a rename on a Finder-style slow second click of an
/// already-selected row's name.
final class SidebarOutlineView: NSOutlineView {
    var contextMenuForRow: ((Int) -> NSMenu?)?
    /// Called with the row to rename on a slow second click of a selected row.
    ///
    /// Fired when the user clicks the name of an already-selected row and no
    /// double-click follows; the controller resolves the row and starts the
    /// inline edit.
    var beginRenameForRow: ((Int) -> Void)?

    /// The item armed for a slow-second-click rename, captured by **identity**.
    ///
    /// Captured by identity (not row index) so a list mutation during the
    /// double-click delay can't retarget the rename to whatever VM now sits at the
    /// old index. Weak so a removed VM simply drops the pending rename.
    private weak var pendingRenameItem: AnyObject?

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
        // cancels the rename instead of racing it. Captured by identity, so the
        // deferred fire re-resolves the item's *current* row.
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
        // selected row — so a list mutation or a single-click that moved the
        // selection elsewhere during the delay can't rename the wrong VM.
        let row = row(forItem: item)
        guard row >= 0, row == selectedRow else { return }
        beginRenameForRow?(row)
    }

    /// Drops any armed slow-second-click rename.
    ///
    /// Called on double-click, selection change, and reload so a stale arm can't
    /// fire later.
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
/// Without this the selection stays emphasized (accent blue) during editing: the
/// field editor is a descendant of the table, and `NSTableRowView`'s emphasis
/// reports `true` whenever the table *contains* the first responder, not only
/// when the table itself is focused. Forcing the grey state for the duration of
/// the edit gives the contrast; the row returns to blue when the edit ends and
/// the outline view is first responder again.
final class SidebarTableRowView: NSTableRowView {
    static let reuseID = NSUserInterfaceItemIdentifier("SidebarTableRow")

    /// Set while the row's name is being edited.
    ///
    /// Forces the selection to the unemphasized grey so the white edit box stands
    /// out. The table won't change emphasis on its own here: the field editor is a
    /// descendant, so from the table's perspective the selection still "contains"
    /// the first responder and stays emphasized. Setting the stored `isEmphasized`
    /// to `false` rebuilds the source-list selection material as grey now (a bare
    /// `needsDisplay` doesn't refresh it); the getter override then keeps it grey
    /// for the duration even if the table re-reads it.
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
    /// after an edit ends: emphasized (blue) when the table is the focused first
    /// responder in a key window, unemphasized (grey) otherwise — the standard
    /// "selected but not focused" look.
    ///
    /// Called for *every* edit end (Return, Escape, and click-commit alike), so a
    /// click that commits but leaves focus in the sidebar correctly returns to
    /// blue instead of being stranded in the editing grey. The source-list
    /// material only rebuilds on a *changed* `isEmphasized` set — during the edit
    /// the stored value was forced `false` — so we toggle to force the rebuild.
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
}
