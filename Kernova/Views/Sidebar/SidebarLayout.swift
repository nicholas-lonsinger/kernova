import Foundation
import KernovaKit

/// The sidebar's rows as values: sections, each listing library entries
/// directly or under group headers.
///
/// ``project(entries:options:retaining:smartGroups:folders:context:)`` is the one function from the library
/// to a layout; ``SidebarTree`` turns a layout into the outline view's items.
/// Each list a layout holds — its sections, a section's groups, a list's
/// entries — keeps the first of any repeated identifier: a repeat would be a
/// second outline item under one key.
@MainActor
struct SidebarLayout {
    @MainActor
    struct Section {
        let id: SidebarSectionID
        let title: String
        let content: Content
        /// What the section lists in place of rows when it has none; `nil` to
        /// list nothing.
        var emptyText: String? = nil
        /// How many VMs the section lists of the library's: always for a smart
        /// group or a folder, and for the library while a filter constrains it.
        var filterCounts: FilterCounts? = nil
    }

    @MainActor
    enum Content {
        case rows(Rows)
        case groups(Groups)

        var isEmpty: Bool {
            switch self {
            case .rows(let rows): rows.entries.isEmpty
            case .groups(let groups): groups.groups.allSatisfy { $0.rows.entries.isEmpty }
            }
        }
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

    /// What the projection reads besides the entries and the options.
    @MainActor
    struct Context {
        /// The guest-agent version this build bundles, `nil` when unknown.
        let bundledAgentVersion: String?
        /// The library's named networks: a VM naming any other is on
        /// ``VMLibraryFilter/Network/unlisted``.
        let networks: [VMNamedNetwork]
        /// What a VM's network reads as —
        /// ``NetworkModeChoice/title(of:entitlements:interfaces:networks:)``
        /// in the app. Asked for each VM while grouping by network, and by the
        /// filter menu.
        let networkTitle: (VMConfiguration) -> String

        /// What a filter reads of `entry`.
        func subject(of entry: LibraryEntry) -> VMLibraryFilter.Subject {
            entry.filterSubject(bundledAgentVersion: bundledAgentVersion, networks: networks)
        }
    }

    /// How many VMs a filtering section lists — a retained VM the filter no
    /// longer matches included — of how many the library holds.
    struct FilterCounts: Equatable {
        let shown: Int
        let total: Int
    }

    static let noMatchesText = "No matching VMs"
    static let emptyFolderText = "Drag VMs here to add them"

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

    /// The layout the sidebar shows for `entries`: a section per smart group,
    /// in `smartGroups`' order, then one per folder, in `folders`' order, then
    /// the library section, listing the entries `options` admits, in its
    /// order, under its groups.
    ///
    /// The entry `retaining` names is listed in the library section whether
    /// or not the filter admits it: the selected VM a change to its own values
    /// took out of the filter, which stays until the selection moves off it.
    static func project(
        entries: [LibraryEntry], options: SidebarViewOptions, retaining: UUID? = nil,
        smartGroups: [VMSmartGroup] = [], folders: [VMFolder] = [], context: Context
    ) -> SidebarLayout {
        // Every entry's subject is read, the retained one's included, so an
        // observation of the projection tracks every value the counts read.
        var subjects: [UUID: VMLibraryFilter.Subject] = [:]
        for entry in entries { subjects[entry.id] = context.subject(of: entry) }
        let matching = Set(entries.filter { subjects[$0.id].map(options.filter.admits) ?? false }.map(\.id))
        let shown = options.sort.ordered(entries.filter { $0.id == retaining || matching.contains($0.id) })
        let content: Content =
            switch options.grouping {
            case .none: .rows(Rows(shown))
            case let grouping:
                .groups(Groups(groups(of: shown, by: grouping, subjects: subjects, context: context)))
            }
        let library = Section(
            id: .library, title: "Virtual Machines", content: content,
            emptyText: options.filter.isActive && !entries.isEmpty ? noMatchesText : nil,
            filterCounts: options.filter.isActive
                ? FilterCounts(shown: shown.count, total: entries.count) : nil)
        return SidebarLayout(
            sections: smartGroups.map { section(for: $0, entries: entries, subjects: subjects, sort: options.sort) }
                + folders.map { section(for: $0, entries: entries, sort: options.sort) }
                + [library])
    }

    /// `folder`'s section: its members the library lists, in `sort`'s order —
    /// under the manual sort, the folder's own — with their count.
    private static func section(for folder: VMFolder, entries: [LibraryEntry], sort: VMLibrarySort) -> Section {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let members = folder.members.compactMap { byID[$0] }
        return Section(
            id: .folder(folder.id), title: folder.name, content: .rows(Rows(sort.ordered(members))),
            emptyText: emptyFolderText, filterCounts: FilterCounts(shown: members.count, total: entries.count))
    }

    /// `group`'s section: the entries its filter admits, in `sort`'s order,
    /// with their count. It retains no entry, so a row whose VM stops matching
    /// leaves it and the selection falls back by ``resolve(_:)``.
    private static func section(
        for group: VMSmartGroup, entries: [LibraryEntry], subjects: [UUID: VMLibraryFilter.Subject],
        sort: VMLibrarySort
    ) -> Section {
        let members = entries.filter { subjects[$0.id].map(group.filter.admits) ?? false }
        return Section(
            id: .smartGroup(group.id), title: group.name, content: .rows(Rows(sort.ordered(members))),
            emptyText: noMatchesText, filterCounts: FilterCounts(shown: members.count, total: entries.count))
    }

    /// One group per distinct value of `grouping` among `entries`, in that
    /// value's order, each listing its entries in `entries`' order.
    private static func groups(
        of entries: [LibraryEntry], by grouping: SidebarGrouping,
        subjects: [UUID: VMLibraryFilter.Subject], context: Context
    ) -> [Group] {
        var pending: [Pending] = []
        for entry in entries {
            guard let subject = subjects[entry.id] else { continue }
            let key = groupKey(of: subject, by: grouping)
            if let index = pending.firstIndex(where: { $0.key == key }) {
                pending[index].entries.append(entry)
                continue
            }
            let title: String =
                switch grouping {
                case .none, .guestOS, .state: key.title
                case .network: networkTitle(subject.network, of: entry.configuration, context: context)
                }
            pending.append(Pending(key: key, title: title, entries: [entry]))
        }
        pending.sort { lhs, rhs in
            if lhs.key.rank != rhs.key.rank { return lhs.key.rank < rhs.key.rank }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return pending.map { group in
            Group(
                id: SidebarGroupID(rawValue: "\(grouping.rawValue):\(group.key.value)"), title: group.title,
                rows: Rows(group.entries))
        }
    }

    /// A group's identity — the value its members share — and where it sorts.
    private struct GroupKey: Equatable {
        let value: String
        let rank: Int
        /// The title, for every grouping but Network, whose title comes from a
        /// member's configuration.
        let title: String
    }

    private struct Pending {
        let key: GroupKey
        let title: String
        var entries: [LibraryEntry]
    }

    private static func groupKey(of subject: VMLibraryFilter.Subject, by grouping: SidebarGrouping) -> GroupKey {
        switch grouping {
        case .none:
            preconditionFailure("An ungrouped section has no groups")
        case .guestOS:
            GroupKey(
                value: subject.guestOS.rawValue, rank: VMGuestOS.allCases.firstIndex(of: subject.guestOS) ?? 0,
                title: subject.guestOS.displayName)
        case .state:
            GroupKey(
                value: subject.state.rawValue, rank: VMStateBucket.allCases.firstIndex(of: subject.state) ?? 0,
                title: subject.state.displayName)
        case .network:
            GroupKey(value: subject.network.rawValue, rank: networkRank(subject.network), title: "")
        }
    }

    /// What `network` reads as, given a VM on it whose configuration is
    /// `configuration`.
    static func networkTitle(
        _ network: VMLibraryFilter.Network, of configuration: VMConfiguration, context: Context
    ) -> String {
        network == .unlisted ? NetworkModeChoice.unlistedNetworkTitle : context.networkTitle(configuration)
    }

    /// What a network a filter holds reads as where no VM is on it to name it.
    ///
    /// A named network the library no longer lists — deleted since the filter
    /// was saved — reads apart from ``VMLibraryFilter/Network/unlisted``: the
    /// filter still holds it, and it admits no VM.
    static func heldNetworkTitle(_ network: VMLibraryFilter.Network, networks: [VMNamedNetwork]) -> String {
        guard let choice = network.choice else { return NetworkModeChoice.unlistedNetworkTitle }
        if case .vmnet(let kind, .network(let id)) = choice,
            !networks.contains(where: { $0.id == id && $0.kind == kind })
        {
            return heldUnlistedNetworkTitle
        }
        return choice.title(attachable: true, interfaces: [], networks: networks)
    }

    /// How a filter names a network it holds that the library no longer lists.
    static let heldUnlistedNetworkTitle = "Network No Longer in This Library"

    /// Where a network sorts among others: the order the Mode picker lists
    /// its choices in, with every network the library does not list after
    /// the vmnet networks it does.
    static func networkRank(_ network: VMLibraryFilter.Network) -> Int {
        guard let choice = network.choice else { return 6 }
        switch choice {
        case .vmnet(let kind, let membership):
            let base = kind == .shared ? 0 : 3
            switch membership {
            case .common: return base
            case .isolated: return base + 1
            case .network: return base + 2
            }
        case .bridged(nil): return 7
        case .bridged: return 8
        case .none: return 9
        }
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

    /// Where `selection` stands once this layout is shown: on the row it
    /// resolves to; on nothing when its entry is still in the library
    /// (`libraryHolds`) but no row lists it; on the first row when its entry
    /// has left the library.
    func reconciled(
        _ selection: SidebarRowKey?, libraryHolds: (UUID) -> Bool
    ) -> SidebarRowKey? {
        guard let selection else { return nil }
        if let row = resolve(selection) { return row }
        return libraryHolds(selection.entryID) ? nil : rowKeys.first
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
