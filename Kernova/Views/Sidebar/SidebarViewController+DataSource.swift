import AppKit
import KernovaKit

/// The outline view's items — the ``SidebarTree``'s nodes — and the drags
/// they make and take.
///
/// A drag carries a VM's row (its ``SidebarRowKey``), a smart group's or a
/// folder's header (its ``SidebarSectionID``), or, from the Finder, `.kernova`
/// bundles. Where each lands is ``drop(of:)``.
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
        // Any section's header drags to reorder the sections.
        if let section = item as? SidebarSection {
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

    /// What a drop does, and the item and child index it is retargeted to.
    private enum Drop {
        case refused
        /// The dragged row's entry joins `folder` (proposed onto the section).
        case join(folder: SidebarSection)
        /// The dragged row moves to the gap `index` of `parent`, within its
        /// own list.
        case reorder(parent: SidebarNode, index: Int)
        /// The dragged header moves to the root gap `index`.
        case moveSection(SidebarSectionID, index: Int)
        /// The bundles are imported, then join `folder` when there is one.
        case importBundles(into: SidebarSection?)
    }

    /// Where the pointer is over the outline: a section, and where in it.
    private struct Spot {
        let section: SidebarSection
        /// The section's offset among the root's children.
        let offset: Int
        /// The gap among the section's children nearest the pointer, `nil`
        /// over the section's header.
        let gap: Int?
        /// Whether the pointer is in the upper half of its row.
        let isUpperHalf: Bool
    }

    /// The spot under `location`, in window coordinates; `nil` below every
    /// row. Where no row is under the pointer but one is below it — the
    /// outline's top inset, the spacing between rows — it is that row's upper
    /// half.
    ///
    /// Every drop is decided from this alone, never from the item and index
    /// AppKit proposes: at the boundary between one section's last row and
    /// the next section's header, AppKit can propose the first section while
    /// the pointer is over the second.
    private func spot(at location: NSPoint) -> Spot? {
        let point = outlineView.convert(location, from: nil)
        var row = outlineView.row(at: point)
        if row < 0 {
            guard
                let below = (0..<outlineView.numberOfRows).first(where: { outlineView.rect(ofRow: $0).minY > point.y })
            else { return nil }
            row = below
        }
        guard let node = outlineView.item(atRow: row) as? SidebarNode else { return nil }
        var top = node
        while let parent = top.parent { top = parent }
        guard let section = top as? SidebarSection, let offset = tree.sections.firstIndex(where: { $0 === section })
        else { return nil }
        let isUpperHalf = point.y < outlineView.rect(ofRow: row).midY
        let gap = section.children.firstIndex { $0 === node }.map { isUpperHalf ? $0 : $0 + 1 }
        return Spot(section: section, offset: offset, gap: gap, isUpperHalf: isUpperHalf)
    }

    /// Where a drag of `info` lands, by the ``Spot`` under the pointer:
    ///
    /// - a row over a folder other than its own section — the header, a row,
    ///   the gaps between them — joins it, unless it holds the VM already;
    /// - a row over its own section reorders its list under the manual sort,
    ///   into the gap nearest the pointer (its list's top over the header):
    ///   the library's order in the library, the folder's own in a folder;
    ///   below every row, it goes to the end of the last section's list;
    /// - a row over any other section is refused. A smart group lists by its
    ///   filter and takes no drop, its own rows' included;
    /// - a header moves among the sections, of any kind: before the section
    ///   under the upper half of its header, else after it; below every row,
    ///   after the last;
    /// - bundles over a folder are imported into it; anywhere else, imported.
    private func drop(of info: NSDraggingInfo) -> Drop {
        let spot = spot(at: info.draggingLocation)
        guard info.draggingSource as? NSOutlineView === outlineView else {
            guard
                info.draggingPasteboard.canReadObject(
                    forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            else { return .refused }
            return .importBundles(into: spot?.section.id.folderID == nil ? nil : spot?.section)
        }
        if let section = draggedSection(info) {
            guard tree.sections.contains(where: { $0.id == section }) else { return .refused }
            let target = spot.map { $0.gap == nil && $0.isUpperHalf ? $0.offset : $0.offset + 1 }
            return .moveSection(section, index: target ?? tree.sections.count)
        }
        guard let source = draggedRow(info) else { return .refused }
        if let spot, spot.section.id != source.key.section {
            guard let id = spot.section.id.folderID,
                viewModel.library.organization.folder(withID: id)?.members.contains(source.key.entryID) == false
            else { return .refused }
            return .join(folder: spot.section)
        }
        guard viewModel.sidebarOptions.sort == .manual, source.key.section.smartGroupID == nil,
            let parent = source.parent, let list = Self.list(of: source)
        else { return .refused }
        // Constrained to the gaps of the dragged row's own list: its group's
        // rows, which follow its header.
        let target: Int
        if let spot {
            target = spot.gap ?? list.lowerBound
        } else {
            guard source.key.section == tree.sections.last?.id else { return .refused }
            target = list.upperBound
        }
        guard (list.lowerBound...list.upperBound).contains(target) else { return .refused }
        return .reorder(parent: parent, index: target)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        switch drop(of: info) {
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
        switch drop(of: info) {
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

    /// Moves the dragged header's section to the root offset it was dropped
    /// at.
    private func acceptSectionMove(_ moved: SidebarSectionID, toSectionIndex index: Int) -> Bool {
        let successor = tree.sections.indices.contains(index) ? tree.sections[index].id : nil
        guard successor != moved else { return false }
        let library = viewModel.library
        attempt("Couldn\u{2019}t Move the Section") { try library.moveSection(moved, before: successor) }
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
