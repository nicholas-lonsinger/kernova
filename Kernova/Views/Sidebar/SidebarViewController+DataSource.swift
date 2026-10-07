import AppKit
import KernovaKit

/// The outline view's items — the ``SidebarTree``'s nodes — and the drags
/// they make and take.
///
/// A drag carries a VM's row (its ``SidebarRowKey``), a smart group's or a
/// folder's header (its ``SidebarSectionID``), or, from the Finder, `.kernova`
/// bundles. Where each lands is ``drop(of:onto:childIndex:)``.
extension SidebarViewController: NSOutlineViewDataSource {
    static let rowPasteboardType = NSPasteboard.PasteboardType("app.kernova.sidebar-vm-row")
    static let sectionPasteboardType = NSPasteboard.PasteboardType("app.kernova.sidebar-section")

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
        // A smart group's or folder's header drags to reorder its kind.
        if let section = item as? SidebarSection {
            guard Self.kind(of: section.id) != nil else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(section.id.rawValue, forType: Self.sectionPasteboardType)
            return pbItem
        }
        // Arrivals are not draggable: their place is settled once they are VMs.
        guard let row = item as? SidebarRow, row.entry.vm != nil,
            let data = try? JSONEncoder().encode(row.key)
        else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setData(data, forType: Self.rowPasteboardType)
        return pbItem
    }

    // MARK: Drop

    /// What a drop does, and the item and child index it is retargeted to —
    /// which, proposed again, decide the same drop.
    private enum Drop {
        case refused
        /// The dragged row's entry joins `folder` (proposed onto the section).
        case join(folder: SidebarSection)
        /// The dragged row moves to the gap `index` of `parent`, within its
        /// own list.
        case reorder(parent: SidebarNode, index: Int)
        /// The dragged header moves to the root gap `index`, among its kind.
        case moveSection(SidebarSectionID, index: Int)
        /// The bundles are imported, then join `folder` when there is one.
        case importBundles(into: SidebarSection?)
    }

    /// Where a drag of `info` proposed at `item` and `index` lands, by the
    /// section it is over:
    ///
    /// - a row over a folder other than its own section — the header, a row,
    ///   the gaps between them — joins it, unless it holds the VM already;
    /// - a row over its own section reorders its list under the manual sort:
    ///   the library's order in the library, the folder's own in a folder;
    /// - a row over any other section is refused. A smart group lists by its
    ///   filter and takes no drop, its own rows' included;
    /// - a header moves among its own kind's headers;
    /// - bundles over a folder are imported into it; anywhere else, imported.
    private func drop(of info: NSDraggingInfo, onto item: Any?, childIndex index: Int) -> Drop {
        let over = section(under: item, at: info.draggingLocation)
        guard info.draggingSource as? NSOutlineView === outlineView else {
            guard
                info.draggingPasteboard.canReadObject(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            else { return .refused }
            return .importBundles(into: over?.id.folderID == nil ? nil : over)
        }
        if let section = draggedSection(info) {
            guard let run = sectionRun(of: section) else { return .refused }
            return .moveSection(section, index: sectionDropIndex(proposedItem: item, childIndex: index, run: run))
        }
        guard let source = draggedRow(info) else { return .refused }
        if let over, over.id != source.key.section {
            guard let id = over.id.folderID,
                viewModel.library.organization.folder(withID: id)?.members.contains(source.key.entryID) == false
            else { return .refused }
            return .join(folder: over)
        }
        guard viewModel.sidebarOptions.sort == .manual, source.key.section.smartGroupID == nil,
            let parent = source.parent, let list = Self.list(of: source)
        else { return .refused }
        // Constrained to the gaps of the dragged row's own list: its group's
        // rows, which follow its header.
        let target: Int
        switch item {
        case let row as SidebarRow:
            guard row.parent === parent, row.key.group == source.key.group else { return .refused }
            target = parent.children.firstIndex { $0 === row } ?? list.upperBound
        case let node as SidebarNode:
            guard node === parent else { return .refused }
            if index == NSOutlineViewDropOnItemIndex {
                target = list.upperBound
            } else {
                guard (list.lowerBound...list.upperBound).contains(index) else { return .refused }
                target = index
            }
        default:
            // A root proposal. Over the dragged row's own section, a gap
            // above it is its list's top; below every row, where AppKit
            // proposes the root with `NSOutlineViewDropOnItemIndex`, is the
            // end of the list of the last section's row.
            let section = tree.sections.firstIndex { $0.id == source.key.section } ?? 0
            guard over != nil || section == tree.sections.count - 1 else { return .refused }
            target =
                index == NSOutlineViewDropOnItemIndex || index > section
                ? list.upperBound : list.lowerBound
        }
        return .reorder(parent: parent, index: target)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        switch drop(of: info, onto: item, childIndex: index) {
        case .refused:
            return []
        case .join(let folder):
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        case .reorder(let parent, let index):
            outlineView.setDropItem(parent, dropChildIndex: index)
            return .move
        case .moveSection(_, let index):
            outlineView.setDropItem(nil, dropChildIndex: index)
            return .move
        case .importBundles(let folder):
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        switch drop(of: info, onto: item, childIndex: index) {
        case .refused:
            return false
        case .join(let folder):
            guard let source = draggedRow(info), let id = folder.id.folderID else { return false }
            attempt("Couldn\u{2019}t Add to the Folder") {
                try viewModel.library.add([source.key.entryID], toFolder: id)
            }
            return true
        case .reorder(let parent, let index):
            guard let source = draggedRow(info) else { return false }
            return acceptReorder(of: source, in: parent, childIndex: index)
        case .moveSection(let section, let index):
            return acceptSectionMove(section, toSectionIndex: index)
        case .importBundles(let folder):
            guard
                let urls = info.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
                ) as? [URL]
            else { return false }
            return viewModel.importVMs(fromDroppedURLs: urls, intoFolder: folder?.id.folderID)
        }
    }

    /// The section `item` is or is listed in; for a root proposal, the one
    /// whose row is under `location` (in window coordinates), which AppKit
    /// proposes as a gap between sections even over a section's header.
    /// `nil` below every row.
    private func section(under item: Any?, at location: NSPoint) -> SidebarSection? {
        var node = item as? SidebarNode
        if node == nil {
            let row = outlineView.row(at: outlineView.convert(location, from: nil))
            node = row >= 0 ? outlineView.item(atRow: row) as? SidebarNode : nil
        }
        while let parent = node?.parent { node = parent }
        return node as? SidebarSection
    }

    /// Which kind of reorderable section `id` is, `nil` for the library.
    private static func kind(of id: SidebarSectionID) -> VMOrganizationDirectory.Kind? {
        if id.smartGroupID != nil { return .smartGroup }
        if id.folderID != nil { return .folder }
        return nil
    }

    /// The root offsets of the sections of `section`'s kind, which the
    /// projection lists together.
    private func sectionRun(of section: SidebarSectionID) -> Range<Int>? {
        guard let kind = Self.kind(of: section) else { return nil }
        let offsets = tree.sections.indices.filter { Self.kind(of: tree.sections[$0].id) == kind }
        guard let first = offsets.first, let last = offsets.last else { return nil }
        return first..<(last + 1)
    }

    /// The root offset within `run` a dragged header lands at: before the
    /// section the drag is over — after it when over the section's own rows —
    /// or at the run's end when below it.
    private func sectionDropIndex(proposedItem item: Any?, childIndex index: Int, run: Range<Int>) -> Int {
        let target: Int
        switch item {
        case nil:
            target = index == NSOutlineViewDropOnItemIndex ? run.upperBound : index
        case let section as SidebarSection:
            let offset = tree.sections.firstIndex { $0 === section } ?? run.upperBound
            target = index == NSOutlineViewDropOnItemIndex || index == 0 ? offset : offset + 1
        case let node as SidebarNode:
            var top = node
            while let parent = top.parent { top = parent }
            target = (tree.sections.firstIndex { $0 === top } ?? run.upperBound) + 1
        default:
            target = run.upperBound
        }
        return min(max(target, run.lowerBound), run.upperBound)
    }

    /// Moves the dragged header's smart group or folder to the root offset it
    /// was dropped at, among its kind.
    private func acceptSectionMove(_ moved: SidebarSectionID, toSectionIndex index: Int) -> Bool {
        guard let run = sectionRun(of: moved) else { return false }
        let successor = index < run.upperBound ? tree.sections[index].id : nil
        guard successor != moved else { return false }
        let library = viewModel.library
        if let id = moved.smartGroupID {
            attempt("Couldn\u{2019}t Move the Smart Group") {
                try library.moveSmartGroup(id, before: successor?.smartGroupID)
            }
        } else if let id = moved.folderID {
            attempt("Couldn\u{2019}t Move the Folder") { try library.moveFolder(id, before: successor?.folderID) }
        }
        return true
    }

    /// Moves the dragged row's entry in its list's manual order — the
    /// library's, or its folder's — to just before the sibling it was dropped
    /// above, or after the last sibling, whatever entries the section leaves
    /// out.
    private func acceptReorder(of source: SidebarRow, in parent: SidebarNode, childIndex: Int) -> Bool {
        guard source.parent === parent, let list = Self.list(of: source) else { return false }
        let visible = parent.children[list].compactMap { ($0 as? SidebarRow)?.key.entryID }
        let entry = source.key.entryID
        let folder = source.key.section.folderID.flatMap { viewModel.library.organization.folder(withID: $0) }
        let order = folder?.members ?? viewModel.entries.map(\.id)
        let index = min(max(childIndex, list.lowerBound), list.upperBound) - list.lowerBound
        guard let sourceIndex = order.firstIndex(of: entry),
            let offset = SidebarLayout.manualOrderOffset(
                moving: entry, toVisibleIndex: index, amongVisible: visible, in: order)
        else { return false }
        guard let folder else {
            viewModel.moveEntries(fromOffsets: IndexSet(integer: sourceIndex), toOffset: offset)
            return true
        }
        let successor = offset < order.count ? order[offset] : nil
        attempt("Couldn\u{2019}t Reorder the Folder") {
            try viewModel.library.move(entry, before: successor, inFolder: folder.id)
        }
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

    /// The row an internal drag carries, while the tree still lists it.
    private func draggedRow(_ info: NSDraggingInfo) -> SidebarRow? {
        guard let data = info.draggingPasteboard.pasteboardItems?.first?.data(forType: Self.rowPasteboardType),
            let key = try? JSONDecoder().decode(SidebarRowKey.self, from: data)
        else { return nil }
        return tree.row(for: key)
    }

    /// The section an internal drag of its header carries.
    private func draggedSection(_ info: NSDraggingInfo) -> SidebarSectionID? {
        info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.sectionPasteboardType)
            .map(SidebarSectionID.init(rawValue:))
    }
}
