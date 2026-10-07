import Foundation

/// The sidebar's rows as values: sections, each listing library entries
/// directly or under group headers.
///
/// ``project(entries:)`` is the one function from the library to a layout;
/// ``SidebarTree`` turns a layout into the outline view's items. Each list a
/// layout holds — its sections, a section's groups, a list's entries — keeps
/// the first of any repeated identifier: a repeat would be a second outline
/// item under one key.
@MainActor
struct SidebarLayout {
    @MainActor
    struct Section {
        let id: SidebarSectionID
        let title: String
        let content: Content
    }

    @MainActor
    enum Content {
        case rows(Rows)
        case groups(Groups)
    }

    @MainActor
    struct Group {
        let id: SidebarGroupID
        let title: String
        let rows: Rows
    }

    /// A section's group headers in display order, each identifier at most once.
    @MainActor
    struct Groups {
        let groups: [Group]

        init(_ groups: [Group]) {
            self.groups = SidebarLayout.firstOfEach(groups, by: \.id)
        }
    }

    /// Entries in display order, each identifier at most once.
    @MainActor
    struct Rows {
        let entries: [LibraryEntry]

        init(_ entries: [LibraryEntry]) {
            self.entries = SidebarLayout.firstOfEach(entries, by: \.id)
        }
    }

    /// The sections in display order, each identifier at most once.
    let sections: [Section]

    init(sections: [Section]) {
        self.sections = Self.firstOfEach(sections, by: \.id)
    }

    private static func firstOfEach<Element, ID: Hashable>(
        _ elements: [Element], by id: (Element) -> ID
    ) -> [Element] {
        var seen = Set<ID>()
        return elements.filter { seen.insert(id($0)).inserted }
    }

    /// The layout the sidebar shows for `entries`: the library section, listing
    /// every entry in manual order.
    static func project(entries: [LibraryEntry]) -> SidebarLayout {
        SidebarLayout(sections: [
            Section(id: .library, title: "Virtual Machines", content: .rows(Rows(entries)))
        ])
    }

    /// Every row's key, in display order.
    var rowKeys: [SidebarRowKey] {
        sections.flatMap { section in
            switch section.content {
            case .rows(let rows):
                rows.entries.map { SidebarRowKey(section: section.id, group: nil, entryID: $0.id) }
            case .groups(let groups):
                groups.groups.flatMap { group in
                    group.rows.entries.map {
                        SidebarRowKey(section: section.id, group: group.id, entryID: $0.id)
                    }
                }
            }
        }
    }

    /// The row `selection` lands on: that row itself, else the first row of
    /// the same entry in the same section, else the entry's first row in the
    /// library section; `nil` when neither section lists the entry.
    func resolve(_ selection: SidebarRowKey) -> SidebarRowKey? {
        let keys = rowKeys
        if keys.contains(selection) { return selection }
        let sameEntry = keys.filter { $0.entryID == selection.entryID }
        return sameEntry.first { $0.section == selection.section }
            ?? sameEntry.first { $0.section == .library }
    }

    /// The `toOffset` that `Array.move(fromOffsets:toOffset:)` takes to move
    /// `moved` within the manual `order` so that it lands at `visibleIndex`
    /// among the rows a section shows, `visible`: just before the visible
    /// neighbor now at that index, or just after the last visible row when the
    /// index is past it. `nil` for a drop into the row's own gap, or one that
    /// leaves it where it is.
    static func manualOrderOffset(
        moving moved: UUID, toVisibleIndex visibleIndex: Int, amongVisible visible: [UUID],
        in order: [UUID]
    ) -> Int? {
        guard let source = order.firstIndex(of: moved) else { return nil }
        let target = min(max(visibleIndex, 0), visible.count)
        if let visibleSource = visible.firstIndex(of: moved),
            target == visibleSource || target == visibleSource + 1
        {
            return nil
        }
        let destination: Int
        if target < visible.count {
            guard let neighbor = order.firstIndex(of: visible[target]) else { return nil }
            destination = neighbor
        } else {
            guard let last = visible.last, let trailing = order.firstIndex(of: last) else {
                return nil
            }
            destination = trailing + 1
        }
        guard destination != source, destination != source + 1 else { return nil }
        return destination
    }
}
