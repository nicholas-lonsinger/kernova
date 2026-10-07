import Foundation
import KernovaKit

/// Which of the library's entries a listing admits, and in what order: a
/// ``VMListQuery`` with every name in it resolved, so reading one fails for
/// no reason.
@MainActor
struct VMLibrarySelection {
    /// The attributes an admitted entry has.
    let filter: VMLibraryFilter
    /// Groups an admitted entry is in, every one of them.
    let groups: [(_ entry: LibraryEntry, _ subject: VMLibraryFilter.Subject) -> Bool]
    /// The order admitted entries are listed in.
    let sort: VMLibrarySort

    /// Every entry, in library order.
    static let all = VMLibrarySelection(filter: VMLibraryFilter(), groups: [], sort: .manual)
}

/// The listing and the library's groups: which VMs a filter, a network or a
/// group admits, by the same subjects and the same filter the sidebar lists
/// them by.
extension VMCommandCore {
    // MARK: - Reads

    func list(_ selection: VMLibrarySelection) -> [VMSummary] {
        library.refreshFromOtherCopies()
        return entries(in: selection).map(summary)
    }

    func groups() throws -> [GroupSummary] {
        library.refreshFromOtherCopies()
        return try readSmartGroups(verb: .groups).map { group in
            let selection = try self.selection(
                for: VMListQuery(groups: [VMGroupReference(.smartGroup, named: group.id.uuidString)]),
                verb: .groups)
            return GroupSummary(
                id: group.id, name: group.name, kind: .smartGroup, members: entries(in: selection).map(summary))
        }
    }

    // MARK: - Resolution

    /// The entries `selection` admits, in its order: each one its filter
    /// admits and in every group it names.
    func entries(in selection: VMLibrarySelection) -> [LibraryEntry] {
        let context = library.sidebarContext
        let admitted = library.entries.filter { entry in
            let subject = context.subject(of: entry)
            return selection.filter.admits(subject) && selection.groups.allSatisfy { $0(entry, subject) }
        }
        return selection.sort.ordered(admitted)
    }

    func selection(for query: VMListQuery, verb: VMVerb) throws -> VMLibrarySelection {
        var filter = query.filter
        if !query.networks.isEmpty { library.networks.reload() }
        for text in query.networks {
            filter.networks.insert(try network(spelledBy: text))
        }
        return VMLibrarySelection(
            filter: filter, groups: try query.groups.map { try membership(of: $0, verb: verb) },
            sort: query.sort)
    }

    /// The network `text` names as a listing reads it: a mode
    /// (``VMLibraryFilter/Network/init(spelling:)``), or a named network by
    /// name or identifier — either ignoring case.
    private func network(spelledBy text: String) throws -> VMLibraryFilter.Network {
        let mode = VMLibraryFilter.Network(spelling: text)
        let named = library.networks.network(named: text)
        switch (mode, named) {
        case (let mode?, nil):
            return mode
        case (nil, let named?):
            return VMLibraryFilter.Network(.vmnet(named.kind, .network(named.id))) { _, _ in true }
        case (_?, let named?):
            throw CommandError.invalidArgument(
                "\u{201C}\(text)\u{201D} names both a network mode and the network \u{201C}\(named.name)\u{201D}. "
                    + "Name that network by its identifier, \(named.id.uuidString).")
        case (nil, nil):
            throw CommandError.itemNotFoundOnHost(item: "network named \u{201C}\(text)\u{201D}")
        }
    }

    /// Whether an entry, reading as `subject`, is in the group `reference`
    /// names.
    private func membership(
        of reference: VMGroupReference, verb: VMVerb
    ) throws -> (_ entry: LibraryEntry, _ subject: VMLibraryFilter.Subject) -> Bool {
        switch reference.kind {
        case .smartGroup:
            _ = try readSmartGroups(verb: verb)
            guard let group = library.organization.smartGroup(named: reference.name) else {
                throw CommandError.itemNotFoundOnHost(item: "smart group named \u{201C}\(reference.name)\u{201D}")
            }
            return { _, subject in group.filter.admits(subject) }
        }
    }

    /// The library's smart groups as its file holds them now, refusing when
    /// the file cannot be read rather than answering none.
    private func readSmartGroups(verb: VMVerb) throws -> [VMSmartGroup] {
        library.organization.reload()
        if let reason = library.organization.readFailure {
            throw CommandError.operationFailed(
                verb: verb, message: "Kernova couldn\u{2019}t read its list of smart groups: \(reason)")
        }
        return library.organization.smartGroups
    }
}
