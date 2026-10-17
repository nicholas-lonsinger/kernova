import Foundation

/// An item of the sidebar's outline view: a ``SidebarSection``, a
/// ``SidebarGroupHeader``, a ``SidebarPlaceholder`` or a ``SidebarRow``.
///
/// `NSOutlineView` keys items on object identity, so ``SidebarTree`` keeps one
/// node per key for as long as its layouts list that key.
@MainActor
package class SidebarNode {
    /// The nodes listed under this one, in display order.
    package fileprivate(set) var children: [SidebarNode] = []

    /// The node this one is listed under; `nil` for a section.
    package fileprivate(set) weak var parent: SidebarNode?

    fileprivate init() {}
}

/// A top-level, collapsible group of the sidebar (e.g. "Virtual Machines").
package final class SidebarSection: SidebarNode {
    package let id: SidebarSectionID
    package fileprivate(set) var title: String
    /// ``SidebarLayout/Section/notice``.
    package fileprivate(set) var notice: String?

    fileprivate init(id: SidebarSectionID, title: String, notice: String?) {
        self.id = id
        self.title = title
        self.notice = notice
    }
}

/// A group header within a section, listed just before its group's rows.
package final class SidebarGroupHeader: SidebarNode {
    let id: SidebarGroupID
    package fileprivate(set) var title: String

    fileprivate init(id: SidebarGroupID, title: String) {
        self.id = id
        self.title = title
    }
}

/// The line a section lists in place of rows when it has none.
package final class SidebarPlaceholder: SidebarNode {
    package fileprivate(set) var text: String

    fileprivate init(text: String) {
        self.text = text
    }
}

/// A library entry's row in one section, under one group header or none.
package final class SidebarRow: SidebarNode {
    package let key: SidebarRowKey

    /// The entry the row shows — replaced in place when an arrival becomes its
    /// VM under the same identifier.
    package fileprivate(set) var entry: LibraryEntry

    fileprivate init(key: SidebarRowKey, entry: LibraryEntry) {
        self.key = key
        self.entry = entry
    }
}

/// The sidebar's outline items for the latest ``SidebarLayout``, and what
/// changed from the previous one.
@MainActor
package final class SidebarTree {
    /// What the outline view has to apply to go from the previous layout to the
    /// current one.
    @MainActor
    package struct Changes {
        /// One parent's child-list change, applied in order: the removals, then
        /// the moves, then the insertions.
        package struct Children {
            /// One child moving within its parent.
            package struct Move: Equatable {
                package let from: Int
                package let to: Int
            }

            /// `nil` for the root, whose children are the sections.
            package let parent: SidebarNode?
            /// Offsets into the parent's previous children.
            package let removed: IndexSet
            /// Each child the parent keeps but in another order, as offsets
            /// into its children as they stand when that move applies — after
            /// the removals and the moves before it.
            package let moves: [Move]
            /// Offsets into the parent's current children.
            package let inserted: IndexSet
            /// The children the moves move.
            fileprivate let moved: [ObjectIdentifier]
        }

        /// The change to every parent present in both layouts whose children
        /// differ. A child that moved within its parent moves, so the outline
        /// keeps the node's expansion.
        package fileprivate(set) var children: [Children] = []

        /// Nodes present in both layouts whose content changed: a row's entry,
        /// or a section's or header's title.
        package fileprivate(set) var reloaded: [SidebarNode] = []

        /// Sections and group headers the current layout added.
        package fileprivate(set) var created: [SidebarNode] = []

        /// Nodes the change takes down or moves: removed from their parent,
        /// moved within it, or rows reloaded.
        fileprivate var detached: Set<ObjectIdentifier> = []

        package var isEmpty: Bool { children.isEmpty && reloaded.isEmpty }

        /// Whether applying the change takes down or moves `node`'s view, directly or
        /// through an ancestor.
        package func detaches(_ node: SidebarNode) -> Bool {
            var candidate: SidebarNode? = node
            while let current = candidate {
                if detached.contains(ObjectIdentifier(current)) { return true }
                candidate = current.parent
            }
            return false
        }
    }

    private struct HeaderKey: Hashable {
        let section: SidebarSectionID
        let group: SidebarGroupID
    }

    /// The root's children.
    package private(set) var sections: [SidebarSection] = []

    /// The layout the tree lists.
    package private(set) var layout = SidebarLayout(sections: [])
    private var sectionsByID: [SidebarSectionID: SidebarSection] = [:]
    private var headersByKey: [HeaderKey: SidebarGroupHeader] = [:]
    private var rowsByKey: [SidebarRowKey: SidebarRow] = [:]
    private var placeholdersBySection: [SidebarSectionID: SidebarPlaceholder] = [:]

    package init() {}

    /// The row listed under `key`.
    package func row(for key: SidebarRowKey) -> SidebarRow? {
        rowsByKey[key]
    }

    /// The row `selection` lands on, by ``SidebarLayout/resolve(_:)``.
    package func row(resolving selection: SidebarRowKey) -> SidebarRow? {
        layout.resolve(selection).flatMap { rowsByKey[$0] }
    }

    /// Makes the tree list `layout`, keeping the node of every key both layouts
    /// list, and answers what changed.
    package func update(to layout: SidebarLayout) -> Changes {
        var changes = Changes()
        var sectionsByID: [SidebarSectionID: SidebarSection] = [:]
        var headersByKey: [HeaderKey: SidebarGroupHeader] = [:]
        var rowsByKey: [SidebarRowKey: SidebarRow] = [:]
        var placeholdersBySection: [SidebarSectionID: SidebarPlaceholder] = [:]

        func retitle(_ node: SidebarNode, from old: String, to new: String, apply: () -> Void) {
            guard old != new else { return }
            apply()
            // Not detached: reloading a title leaves the rows' views up.
            changes.reloaded.append(node)
        }

        func setChildren(of parent: SidebarNode, to children: [SidebarNode], isNew: Bool) {
            if !isNew, let change = Self.change(from: parent.children, to: children, in: parent) {
                for offset in change.removed {
                    changes.detached.insert(ObjectIdentifier(parent.children[offset]))
                }
                changes.detached.formUnion(change.moved)
                changes.children.append(change)
            }
            parent.children = children
            for child in children { child.parent = parent }
        }

        func rows(
            _ rows: SidebarLayout.Rows, section: SidebarSectionID, group: SidebarGroupID?
        ) -> [SidebarNode] {
            rows.entries.map { entry in
                let key = SidebarRowKey(section: section, group: group, entryID: entry.id)
                let node: SidebarRow
                if let existing = self.rowsByKey[key] {
                    node = existing
                    if existing.entry.object !== entry.object {
                        existing.entry = entry
                        changes.reloaded.append(existing)
                        changes.detached.insert(ObjectIdentifier(existing))
                    }
                } else {
                    node = SidebarRow(key: key, entry: entry)
                }
                rowsByKey[key] = node
                return node
            }
        }

        // A group header and its rows are siblings, each header listed just
        // before its rows: an outline view that has once shown a level below
        // the section keeps indenting that section's rows as if one were
        // there, through every reload (observed macOS 27.2, 2026-10-07), so the sidebar
        // never nests one.
        func header(_ group: SidebarLayout.Group, in section: SidebarSectionID) -> [SidebarNode] {
            let key = HeaderKey(section: section, group: group.id)
            let existing = self.headersByKey[key]
            let header = existing ?? SidebarGroupHeader(id: group.id, title: group.title)
            if let existing {
                retitle(existing, from: existing.title, to: group.title) { existing.title = group.title }
            } else {
                changes.created.append(header)
            }
            headersByKey[key] = header
            return [header] + rows(group.rows, section: section, group: group.id)
        }

        var newSections: [SidebarSection] = []
        for spec in layout.sections {
            let existing = self.sectionsByID[spec.id]
            let section = existing ?? SidebarSection(id: spec.id, title: spec.title, notice: spec.notice)
            if let existing {
                retitle(existing, from: existing.title, to: spec.title) { existing.title = spec.title }
                retitle(existing, from: existing.notice ?? "", to: spec.notice ?? "") { existing.notice = spec.notice }
            } else {
                changes.created.append(section)
            }
            sectionsByID[spec.id] = section
            let children: [SidebarNode]
            if spec.content.isEmpty, let text = spec.emptyText {
                let existing = self.placeholdersBySection[spec.id]
                let placeholder = existing ?? SidebarPlaceholder(text: text)
                if let existing {
                    retitle(existing, from: existing.text, to: text) { existing.text = text }
                }
                placeholdersBySection[spec.id] = placeholder
                children = [placeholder]
            } else {
                children =
                    switch spec.content {
                    case .rows(let entries): rows(entries, section: spec.id, group: nil)
                    case .groups(let groups): groups.groups.flatMap { header($0, in: spec.id) }
                    }
            }
            setChildren(of: section, to: children, isNew: existing == nil)
            newSections.append(section)
        }
        if let change = Self.change(from: sections, to: newSections, in: nil) {
            changes.children.append(change)
        }
        // Every node the layout dropped, descendants of a dropped node
        // included: once dropped, a node's weak parent chain no longer leads
        // to the ancestor that took it down.
        let kept = Set(
            sectionsByID.values.map { ObjectIdentifier($0) }
                + headersByKey.values.map { ObjectIdentifier($0) }
                + rowsByKey.values.map { ObjectIdentifier($0) }
                + placeholdersBySection.values.map { ObjectIdentifier($0) })
        let previous: [SidebarNode] =
            Array(self.sectionsByID.values) + Array(self.headersByKey.values)
            + Array(self.rowsByKey.values) + Array(self.placeholdersBySection.values)
        for node in previous where !kept.contains(ObjectIdentifier(node)) {
            changes.detached.insert(ObjectIdentifier(node))
        }

        sections = newSections
        self.layout = layout
        self.sectionsByID = sectionsByID
        self.headersByKey = headersByKey
        self.rowsByKey = rowsByKey
        self.placeholdersBySection = placeholdersBySection
        return changes
    }

    /// The removals, moves and insertions that turn `old` into `new`,
    /// compared by identity; `nil` when they are the same list.
    ///
    /// The children both lists hold are moved, never removed and reinserted,
    /// into `new`'s order before anything is inserted, so each insertion's
    /// offset is final. The children that move are the fewest the reorder
    /// needs — those off the lists' longest common subsequence — and each
    /// lands just after the child `new` lists before it.
    private static func change(
        from old: [SidebarNode], to new: [SidebarNode], in parent: SidebarNode?
    ) -> Changes.Children? {
        let oldIDs = old.map(ObjectIdentifier.init)
        let newIDs = new.map(ObjectIdentifier.init)
        guard oldIDs != newIDs else { return nil }
        let kept = Set(oldIDs).intersection(newIDs)
        let removed = IndexSet(oldIDs.indices.filter { !kept.contains(oldIDs[$0]) })
        let inserted = IndexSet(newIDs.indices.filter { !kept.contains(newIDs[$0]) })
        var current = oldIDs.filter(kept.contains)
        let target = newIDs.filter(kept.contains)
        let moving = Set(
            target.difference(from: current).compactMap { step -> ObjectIdentifier? in
                guard case .insert(_, let id, _) = step else { return nil }
                return id
            })
        var moves: [Changes.Children.Move] = []
        for (offset, id) in target.enumerated() where moving.contains(id) {
            guard let from = current.firstIndex(of: id) else { continue }
            current.remove(at: from)
            let to = offset == 0 ? 0 : (current.firstIndex(of: target[offset - 1]).map { $0 + 1 } ?? 0)
            current.insert(id, at: to)
            moves.append(Changes.Children.Move(from: from, to: to))
        }
        return Changes.Children(
            parent: parent, removed: removed, moves: moves, inserted: inserted,
            moved: target.filter(moving.contains))
    }
}
