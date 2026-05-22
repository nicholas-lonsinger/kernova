import AppKit
import UniformTypeIdentifiers
import os

/// AppKit sidebar source-list controller.
///
/// Replaces the SwiftUI `SidebarView` previously hosted via
/// `NSHostingController` inside `MainWindowController`. Manages an
/// `NSOutlineView` configured as a source list with one always-expanded
/// group ("Virtual Machines") whose children are the library's
/// `VMInstance`s.
///
/// Responsibilities:
///   - Mirror `viewModel.instances` into the outline view; preserve the
///     selected row across reloads.
///   - Bridge selection between `viewModel.selectedID` (model-of-truth)
///     and the outline view's row selection.
///   - Drag-reorder rows internally and accept dropped `.kernova` bundles
///     for import.
///   - Build the per-row, status-conditional context menu via
///     ``SidebarContextMenuProvider``.
///
/// Row content (icon + name + subtitle + status indicator + agent badge)
/// lives in ``SidebarRowView`` and is added in phase 7c. The shell built
/// here renders a placeholder row (icon + name) until then.
@MainActor
final class SidebarViewController: NSViewController {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "SidebarVC")
    private static let reorderPasteboardType = NSPasteboard.PasteboardType("com.kernova.vmrow.reorder")
    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("VMRow")
    private static let groupRowIdentifier = NSUserInterfaceItemIdentifier("VMGroup")

    private let viewModel: VMLibraryViewModel
    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()

    private var instancesObservation: ObservationLoop?
    private var selectionObservation: ObservationLoop?
    private var renameObservation: ObservationLoop?

    /// Guards against feedback loops: when the view model's selection
    /// changes drive the outline view's selection, the resulting
    /// `outlineViewSelectionDidChange` would otherwise write back to the
    /// view model with the same value.
    private var isApplyingSelectionFromObserver = false

    /// Snapshot of `viewModel.instances` ordering used to detect when
    /// `reloadData()` is actually needed (vs. a property change inside an
    /// existing row, which a row-level observer handles).
    private var cachedInstanceIDs: [UUID] = []

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarViewController does not support NSCoder")
    }

    // MARK: - View lifecycle

    override func loadView() {
        view = NSView()

        configureOutlineView()
        configureScrollView()
        view.addFullSizeSubview(scrollView)
    }

    private func configureOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Main"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 0
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = false
        outlineView.allowsColumnSelection = false
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.rowSizeStyle = .default
        outlineView.autosaveExpandedItems = false

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.contextMenuProvider = self

        outlineView.doubleAction = #selector(handlePrimaryAction(_:))
        outlineView.target = self

        outlineView.registerForDraggedTypes([Self.reorderPasteboardType, .fileURL])
        outlineView.setDraggingSourceOperationMask([.move], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy], forLocal: false)
    }

    private func configureScrollView() {
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload(force: true)
        outlineView.expandItem(SidebarGroupItem.shared, expandChildren: false)
        applySelection()

        if instancesObservation == nil {
            observeInstances()
        }
        if selectionObservation == nil {
            observeSelection()
        }
        if renameObservation == nil {
            observeRename()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        instancesObservation?.cancel()
        instancesObservation = nil
        selectionObservation?.cancel()
        selectionObservation = nil
        renameObservation?.cancel()
        renameObservation = nil
    }

    // MARK: - Observation

    private func observeInstances() {
        instancesObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.viewModel.instances.map { $0.id }
            },
            apply: { [weak self] in
                self?.reload(force: false)
            }
        )
    }

    private func observeSelection() {
        selectionObservation = observeRecurring(
            track: { [weak self] in
                _ = self?.viewModel.selectedID
            },
            apply: { [weak self] in
                self?.applySelection()
            }
        )
    }

    private func observeRename() {
        renameObservation = observeRecurring(
            track: { [weak self] in
                _ = self?.viewModel.activeRename
            },
            apply: { [weak self] in
                self?.applyActiveRename()
            }
        )
    }

    private func applyActiveRename() {
        guard case let .sidebar(id) = viewModel.activeRename else {
            // Tell every visible row to exit rename mode. The cheap way
            // is to walk visible rows; we keep it tight by only touching
            // those reporting in-rename via `isInRenameMode`.
            for row in visibleSidebarRowViews() {
                row.exitRenameMode()
            }
            return
        }
        guard let instance = viewModel.instances.first(where: { $0.id == id }) else {
            // Renaming target disappeared (race with delete) — clear the flag.
            viewModel.cancelRename()
            return
        }
        let row = outlineView.row(forItem: instance)
        guard row >= 0,
            let rowView = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? SidebarRowView
        else { return }
        rowView.enterRenameMode()
    }

    private func visibleSidebarRowViews() -> [SidebarRowView] {
        var result: [SidebarRowView] = []
        let rowRange = outlineView.rows(in: outlineView.visibleRect)
        for row in rowRange.lowerBound..<rowRange.upperBound {
            if let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? SidebarRowView
            {
                result.append(view)
            }
        }
        return result
    }

    // MARK: - Reload + selection

    private func reload(force: Bool) {
        let newIDs = viewModel.instances.map(\.id)
        let needsReload = force || newIDs != cachedInstanceIDs
        cachedInstanceIDs = newIDs
        guard needsReload else { return }
        outlineView.reloadItem(SidebarGroupItem.shared, reloadChildren: true)
        outlineView.expandItem(SidebarGroupItem.shared, expandChildren: false)
        applySelection()
    }

    private func applySelection() {
        let targetRow: Int
        if let id = viewModel.selectedID,
            let instance = viewModel.instances.first(where: { $0.id == id })
        {
            targetRow = outlineView.row(forItem: instance)
        } else {
            targetRow = -1
        }
        if targetRow >= 0 {
            guard outlineView.selectedRow != targetRow else { return }
            isApplyingSelectionFromObserver = true
            outlineView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            isApplyingSelectionFromObserver = false
        } else if outlineView.selectedRow != -1 {
            isApplyingSelectionFromObserver = true
            outlineView.deselectAll(nil)
            isApplyingSelectionFromObserver = false
        }
    }

    // MARK: - Actions

    @objc private func handlePrimaryAction(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let instance = outlineView.item(atRow: row) as? VMInstance else { return }
        guard !instance.isPreparing else { return }
        if instance.status.canStart {
            Task { await viewModel.start(instance) }
        } else if instance.status.canResume {
            Task { await viewModel.resume(instance) }
        }
    }

    private func instance(from sender: Any?) -> VMInstance? {
        guard let item = sender as? NSMenuItem else { return nil }
        return item.representedObject as? VMInstance
    }

    @objc private func startVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        Task { await viewModel.start(instance) }
    }

    @objc private func pauseVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        Task { await viewModel.pause(instance) }
    }

    @objc private func resumeVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        Task { await viewModel.resume(instance) }
    }

    @objc private func stopVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        viewModel.stop(instance)
    }

    @objc private func forceStopVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        viewModel.confirmForceStop(instance)
    }

    @objc private func suspendVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        Task { await viewModel.save(instance) }
    }

    @objc private func renameVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        viewModel.renameVMInSidebar(instance)
    }

    @objc private func cloneVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        viewModel.cloneVM(instance)
    }

    @objc private func showInFinderAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
    }

    @objc private func deleteVMAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        viewModel.confirmDelete(instance)
    }

    @objc private func cancelPreparingAction(_ sender: NSMenuItem) {
        guard let instance = instance(from: sender) else { return }
        viewModel.confirmCancelPreparing(instance)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return 1 }
        if item as? SidebarGroupItem === SidebarGroupItem.shared {
            return viewModel.instances.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return SidebarGroupItem.shared }
        if item as? SidebarGroupItem === SidebarGroupItem.shared {
            return viewModel.instances[index]
        }
        Self.logger.fault("Unexpected child(\(index, privacy: .public)) request for unknown item")
        assertionFailure("Unexpected child request")
        return SidebarGroupItem.shared
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item as? SidebarGroupItem === SidebarGroupItem.shared
    }

    // MARK: Drag source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let instance = item as? VMInstance else { return nil }
        guard !instance.isPreparing else { return nil }
        let row = outlineView.row(forItem: instance)
        guard row >= 0 else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString("\(row)", forType: Self.reorderPasteboardType)
        return pbItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Drop must land inside the group at a specific child index, not on
        // a row or above the group itself.
        guard let proposed = item as? SidebarGroupItem, proposed === SidebarGroupItem.shared else {
            return []
        }
        guard index >= 0 else { return [] }

        let pasteboard = info.draggingPasteboard

        // Internal reorder
        if pasteboard.types?.contains(Self.reorderPasteboardType) == true {
            return .move
        }

        // External bundle import (Finder drop)
        if hasImportableBundleURL(on: pasteboard) {
            return .copy
        }

        return []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let pasteboard = info.draggingPasteboard

        if let raw = pasteboard.string(forType: Self.reorderPasteboardType),
            let source = Int(raw)
        {
            // child indices include the group row at 0; the instance row
            // indices in the outline are 1...count. `outlineView.row(forItem:)`
            // already returns table-row indexes, so we use those directly.
            guard let sourceItem = outlineView.item(atRow: source) as? VMInstance else { return false }
            guard let sourceOffset = viewModel.instances.firstIndex(where: { $0 === sourceItem }) else {
                return false
            }
            let target = max(0, index)
            viewModel.moveVM(fromOffsets: IndexSet(integer: sourceOffset), toOffset: target)
            return true
        }

        let urls = importableBundleURLs(on: pasteboard)
        guard !urls.isEmpty else { return false }
        for url in urls {
            viewModel.importVM(from: url)
        }
        return true
    }

    private func hasImportableBundleURL(on pasteboard: NSPasteboard) -> Bool {
        !importableBundleURLs(on: pasteboard).isEmpty
    }

    /// Internal so unit tests can verify the drop-URL filter without
    /// reconstructing an `NSDraggingInfo`.
    func importableBundleURLs(on pasteboard: NSPasteboard) -> [URL] {
        guard
            let items = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [
                    .urlReadingFileURLsOnly: true
                ])
                as? [URL]
        else { return [] }
        return items.filter { $0.pathExtension == VMStorageService.bundleExtension }
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item as? SidebarGroupItem === SidebarGroupItem.shared
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Group row is not selectable
        !(item as? SidebarGroupItem === SidebarGroupItem.shared)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if item as? SidebarGroupItem === SidebarGroupItem.shared {
            return makeGroupRow()
        }
        if let instance = item as? VMInstance {
            return makeInstanceRow(for: instance)
        }
        return nil
    }

    private func makeGroupRow() -> NSView {
        let label = NSTextField(labelWithString: "Virtual Machines")
        label.font = NSFont.preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabelColor
        label.identifier = Self.groupRowIdentifier
        return label
    }

    private func makeInstanceRow(for instance: VMInstance) -> NSView {
        let view: SidebarRowView
        if let dequeued = outlineView.makeView(withIdentifier: Self.rowViewIdentifier, owner: self)
            as? SidebarRowView
        {
            view = dequeued
        } else {
            view = SidebarRowView(viewModel: viewModel)
            view.identifier = Self.rowViewIdentifier
        }
        view.configure(instance)
        return view
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelectionFromObserver else { return }
        let row = outlineView.selectedRow
        if row >= 0, let instance = outlineView.item(atRow: row) as? VMInstance {
            if viewModel.selectedID != instance.id {
                viewModel.selectedID = instance.id
            }
        } else if viewModel.selectedID != nil {
            viewModel.selectedID = nil
        }
    }
}

// MARK: - SidebarContextMenuProvider

extension SidebarViewController: SidebarContextMenuProvider {
    func sidebarContextMenu(at point: NSPoint, row: Int) -> NSMenu? {
        guard row >= 0, let instance = outlineView.item(atRow: row) as? VMInstance else {
            return nil
        }
        return buildContextMenu(for: instance)
    }

    /// Internal so unit tests can inspect the menu produced for each status
    /// without driving an event-based right-click.
    func buildContextMenu(for instance: VMInstance) -> NSMenu {
        let menu = NSMenu()

        if let preparing = instance.preparingState {
            menu.addItem(
                contextItem(
                    title: preparing.operation.cancelLabel,
                    action: #selector(cancelPreparingAction(_:)),
                    instance: instance
                )
            )
            menu.addItem(
                contextItem(
                    title: "Show in Finder",
                    action: #selector(showInFinderAction(_:)),
                    instance: instance
                )
            )
            return menu
        }

        // Lifecycle
        if instance.status.canStart {
            menu.addItem(
                contextItem(
                    title: startButtonLabel(for: instance),
                    action: #selector(startVMAction(_:)),
                    instance: instance
                )
            )
        }
        if instance.status.canPause {
            menu.addItem(
                contextItem(
                    title: "Pause",
                    action: #selector(pauseVMAction(_:)),
                    instance: instance
                )
            )
        }
        if instance.status.canResume {
            menu.addItem(
                contextItem(
                    title: "Resume",
                    action: #selector(resumeVMAction(_:)),
                    instance: instance
                )
            )
        }
        if instance.canStop {
            menu.addItem(
                contextItem(
                    title: "Stop",
                    action: #selector(stopVMAction(_:)),
                    instance: instance
                )
            )
        }
        if instance.isColdPaused {
            menu.addItem(
                contextItem(
                    title: "Discard Saved State",
                    action: #selector(forceStopVMAction(_:)),
                    instance: instance
                )
            )
        } else if instance.status.canForceStop && !instance.status.canStop {
            menu.addItem(
                contextItem(
                    title: "Force Stop",
                    action: #selector(forceStopVMAction(_:)),
                    instance: instance
                )
            )
        }

        // State
        if instance.canSave {
            menu.addItem(.separator())
            menu.addItem(
                contextItem(
                    title: "Suspend",
                    action: #selector(suspendVMAction(_:)),
                    instance: instance
                )
            )
        }

        // Display (AppDelegate handles toggle via responder chain)
        if instance.canUseExternalDisplay {
            menu.addItem(.separator())
            let popOutTitle = instance.isInSeparateWindow ? "Pop In Display" : "Pop Out Display"
            menu.addItem(
                responderChainItem(
                    title: popOutTitle,
                    action: #selector(AppDelegate.togglePopOut(_:))
                )
            )
            let fullscreenTitle = instance.isInFullscreen ? "Exit Fullscreen Display" : "Fullscreen Display"
            menu.addItem(
                responderChainItem(
                    title: fullscreenTitle,
                    action: #selector(AppDelegate.toggleFullscreen(_:))
                )
            )
        }

        menu.addItem(.separator())

        // Management
        let renameItem = contextItem(
            title: "Rename",
            action: #selector(renameVMAction(_:)),
            instance: instance
        )
        renameItem.isEnabled = instance.status.canRename
        menu.addItem(renameItem)

        let cloneItem = contextItem(
            title: "Clone",
            action: #selector(cloneVMAction(_:)),
            instance: instance
        )
        cloneItem.isEnabled = instance.status.canEditSettings && !viewModel.hasPreparing
        menu.addItem(cloneItem)

        menu.addItem(
            contextItem(
                title: "Show in Finder",
                action: #selector(showInFinderAction(_:)),
                instance: instance
            )
        )

        menu.addItem(.separator())

        // Destructive
        let deleteItem = contextItem(
            title: "Move to Trash",
            action: #selector(deleteVMAction(_:)),
            instance: instance
        )
        deleteItem.isEnabled = instance.status.canEditSettings
        menu.addItem(deleteItem)

        return menu
    }

    private func contextItem(title: String, action: Selector, instance: VMInstance) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = instance
        return item
    }

    /// Builds a menu item whose target is left `nil`, so AppKit's responder
    /// chain routes the action through `AppDelegate` (matching the existing
    /// pattern for pop-out / fullscreen commands).
    private func responderChainItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = nil
        return item
    }

    private func startButtonLabel(for instance: VMInstance) -> String {
        #if arch(arm64)
        guard instance.configuration.installContext != nil else { return "Start" }
        return instance.hasResumableInstallDownload ? "Resume Install" : "Install"
        #else
        return "Start"
        #endif
    }
}
