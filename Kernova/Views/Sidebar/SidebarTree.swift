import Foundation

/// An item of the sidebar's outline view: a ``SidebarSection``, a
/// ``SidebarGroupHeader``, a ``SidebarPlaceholder`` or a ``SidebarRow``.
///
/// `NSOutlineView` keys items on object identity, so ``SidebarTree`` keeps one
/// node per key for as long as its layouts list that key.
@MainActor
class SidebarNode {
    /// The nodes listed under this one, in display order.
    fileprivate(set) var children: [SidebarNode] = []

    /// The node this one is listed under; `nil` for a section.
    fileprivate(set) weak var parent: SidebarNode?

    fileprivate init() {}
}

/// A top-level, collapsible group of the sidebar (e.g. "Virtual Machines").
final class SidebarSection: SidebarNode {
    let id: SidebarSectionID
    fileprivate(set) var title: String

    fileprivate init(id: SidebarSectionID, title: String) {
        self.id = id
        self.title = title
    }
}

/// A group header within a section.
final class SidebarGroupHeader: SidebarNode {
    let id: SidebarGroupID
    fileprivate(set) var title: String

    fileprivate init(id: SidebarGroupID, title: String) {
        self.id = id
        self.title = title
    }
}

/// The line a section lists in place of rows when it has none.
final class SidebarPlaceholder: SidebarNode {
    fileprivate(set) var text: String

    fileprivate init(text: String) {
        self.text = text
    }
}

/// A library entry's row in one section, under one group header or none.
final class SidebarRow: SidebarNode {
    let key: SidebarRowKey

    /// The entry the row shows — replaced in place when an arrival becomes its
    /// VM under the same identifier.
    fileprivate(set) var entry: LibraryEntry

    fileprivate init(key: SidebarRowKey, entry: LibraryEntry) {
        self.key = key
        self.entry = entry
    }
}

/// The sidebar's outline items for the latest ``SidebarLayout``, and what
/// changed from the previous one.
@MainActor
final class SidebarTree {
    /// What the outline view has to apply to go from the previous layout to the
    /// current one.
    @MainActor
    struct Changes {
        /// One parent's child-list change.
        struct Children {
            /// `nil` for the root, whose children are the sections.
            let parent: SidebarNode?
            /// Offsets into the parent's previous children.
            let removed: IndexSet
            /// Offsets into the parent's current children.
            let inserted: IndexSet
        }

        /// The change to every parent present in both layouts whose children
        /// differ. A child that moved within its parent is removed and
        /// inserted.
        fileprivate(set) var children: [Children] = []

        /// Nodes present in both layouts whose content changed: a row's entry,
        /// or a section's or header's title.
        fileprivate(set) var reloaded: [SidebarNode] = []

        /// Sections and group headers the current layout added.
        fileprivate(set) var created: [SidebarNode] = []

        /// Nodes whose views the change takes down: removed from their parent,
        /// moved within it, or rows reloaded.
        fileprivate var detached: Set<ObjectIdentifier> = []

        var isEmpty: Bool { children.isEmpty && reloaded.isEmpty }

        /// Whether applying the change takes `node`'s view down, directly or
        /// through an ancestor.
        func detaches(_ node: SidebarNode) -> Bool {
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
    private(set) var sections: [SidebarSection] = []

    /// The layout the tree lists.
    private(set) var layout = SidebarLayout(sections: [])
    private var sectionsByID: [SidebarSectionID: SidebarSection] = [:]
    private var headersByKey: [HeaderKey: SidebarGroupHeader] = [:]
    private var rowsByKey: [SidebarRowKey: SidebarRow] = [:]
    private var placeholdersBySection: [SidebarSectionID: SidebarPlaceholder] = [:]

    /// The row listed under `key`.
    func row(for key: SidebarRowKey) -> SidebarRow? {
        rowsByKey[key]
    }

    /// The row `selection` lands on, by ``SidebarLayout/resolve(_:)``.
    func row(resolving selection: SidebarRowKey) -> SidebarRow? {
        layout.resolve(selection).flatMap { rowsByKey[$0] }
    }

    /// Makes the tree list `layout`, keeping the node of every key both layouts
    /// list, and answers what changed.
    func update(to layout: SidebarLayout) -> Changes {
        var changes = Changes()
        var sectionsByID: [SidebarSectionID: SidebarSection] = [:]
        var headersByKey: [HeaderKey: SidebarGroupHeader] = [:]
        var rowsByKey: [SidebarRowKey: SidebarRow] = [:]
        var placeholdersBySection: [SidebarSectionID: SidebarPlaceholder] = [:]

        func retitle(_ node: SidebarNode, from old: String, to new: String, apply: () -> Void) {
            guard old != new else { return }
            apply()
            // Not detached: reloading a header leaves its children's views up.
            changes.reloaded.append(node)
        }

        func setChildren(of parent: SidebarNode, to children: [SidebarNode], isNew: Bool) {
            if !isNew, let change = Self.change(from: parent.children, to: children, in: parent) {
                for offset in change.removed {
                    changes.detached.insert(ObjectIdentifier(parent.children[offset]))
                }
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

        func header(_ group: SidebarLayout.Group, in section: SidebarSectionID) -> SidebarNode {
            let key = HeaderKey(section: section, group: group.id)
            let existing = self.headersByKey[key]
            let header = existing ?? SidebarGroupHeader(id: group.id, title: group.title)
            if let existing {
                retitle(existing, from: existing.title, to: group.title) { existing.title = group.title }
            } else {
                changes.created.append(header)
            }
            headersByKey[key] = header
            setChildren(
                of: header, to: rows(group.rows, section: section, group: group.id),
                isNew: existing == nil)
            return header
        }

        var newSections: [SidebarSection] = []
        for spec in layout.sections {
            let existing = self.sectionsByID[spec.id]
            let section = existing ?? SidebarSection(id: spec.id, title: spec.title)
            if let existing {
                retitle(existing, from: existing.title, to: spec.title) { existing.title = spec.title }
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
                    case .groups(let groups): groups.groups.map { header($0, in: spec.id) }
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

    /// The removals and insertions that turn `old` into `new`, compared by
    /// identity; `nil` when they are the same list.
    private static func change(
        from old: [SidebarNode], to new: [SidebarNode], in parent: SidebarNode?
    ) -> Changes.Children? {
        let difference = new.map(ObjectIdentifier.init).difference(from: old.map(ObjectIdentifier.init))
        guard !difference.isEmpty else { return nil }
        var removed = IndexSet()
        var inserted = IndexSet()
        for step in difference {
            switch step {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        return Changes.Children(parent: parent, removed: removed, inserted: inserted)
    }
}
