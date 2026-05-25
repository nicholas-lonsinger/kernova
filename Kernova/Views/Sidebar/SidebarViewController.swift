import AppKit
import UniformTypeIdentifiers
import os

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

    private static let rowPasteboardType = NSPasteboard.PasteboardType("com.kernova.sidebar-vm-row")
    private static let groupCellID = NSUserInterfaceItemIdentifier("SidebarGroupHeaderCell")
    private static let mainColumnID = NSUserInterfaceItemIdentifier("main")
    private static let expandedSectionsKey = "KernovaSidebarExpandedSections"
    private static let leafRowHeight: CGFloat = 42
    private static let groupRowHeight: CGFloat = 24

    private static let logger = Logger(subsystem: "com.kernova.app", category: "SidebarViewController")

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
        outlineView.reloadData()
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
        guard row >= 0, outlineView.selectedRow != row else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
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

        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? SidebarVMRowCellView
        {
            cell.setRenaming(true)
        }
    }

    private func endActiveEditingIfNeeded() {
        guard let id = editingItemID else { return }
        editingItemID = nil
        guard let instance = viewModel.instances.first(where: { $0.id == id }) else { return }
        let row = outlineView.row(forItem: instance)
        guard row >= 0,
            let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarVMRowCellView
        else { return }
        cell.setRenaming(false)
    }

    // MARK: - Double-click

    @objc private func rowDoubleClicked(_ sender: Any?) {
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
        for url in urls where url.pathExtension == VMStorageService.bundleExtension {
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
            onCommitRename: { [weak self] newName in
                self?.viewModel.commitRename(for: instance, newName: newName)
            },
            onCancelRename: { [weak self] in
                self?.viewModel.cancelRename()
            },
            onMountAgent: { [weak self] in
                self?.viewModel.mountGuestAgentInstaller(on: instance)
            },
            onDismissAgentNudge: { [weak self] in
                self?.viewModel.dismissAgentInstallNudge(for: instance)
            }
        )
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelectionFromModel else { return }
        let row = outlineView.selectedRow
        let newID = (row >= 0 ? outlineView.item(atRow: row) as? VMInstance : nil)?.id
        if viewModel.selectedID != newID {
            viewModel.selectedID = newID
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        persistExpansion()
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
        if status.canStart {
            menu.addItem(item(startButtonLabel(for: instance), #selector(menuStart(_:)), instance))
        }
        if status.canPause {
            menu.addItem(item("Pause", #selector(menuPause(_:)), instance))
        }
        if status.canResume {
            menu.addItem(item("Resume", #selector(menuResume(_:)), instance))
        }
        if instance.canStop {
            menu.addItem(item("Stop", #selector(menuStop(_:)), instance))
        }
        if instance.isColdPaused {
            menu.addItem(item("Discard Saved State", #selector(menuForceStop(_:)), instance))
        } else if status.canForceStop && !status.canStop {
            menu.addItem(item("Force Stop", #selector(menuForceStop(_:)), instance))
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

        // Destructive
        let trash = item("Move to Trash", #selector(menuMoveToTrash(_:)), instance)
        trash.isEnabled = status.canEditSettings
        menu.addItem(trash)

        return menu
    }

    /// Mirrors the former SwiftUI Start label: distinguishes install/boot for
    /// macOS guests with a pending install context.
    private func startButtonLabel(for instance: VMInstance) -> String {
        #if arch(arm64)
        guard instance.configuration.installContext != nil else { return "Start" }
        return instance.hasResumableInstallDownload ? "Resume Install" : "Install"
        #else
        return "Start"
        #endif
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

    @objc private func menuCancelPreparing(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? VMInstance else { return }
        viewModel.confirmCancelPreparing(instance)
    }
}

// MARK: - Outline view subclass

/// `NSOutlineView` subclass that routes right-clicks to a controller-supplied
/// menu builder, resolving the clicked row itself.
final class SidebarOutlineView: NSOutlineView {
    var contextMenuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuForRow?(row(at: point))
    }
}
