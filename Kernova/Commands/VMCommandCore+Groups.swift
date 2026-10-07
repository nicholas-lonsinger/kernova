import Foundation
import KernovaKit

/// The narrowed listing and the library's groups: which VMs a filter, a named
/// network or a group admits, by the same subjects and the same filter the
/// sidebar lists them by.
extension VMCommandCore {
    // MARK: - Reads

    func list(_ query: VMListQuery) throws -> [VMSummary] {
        library.refreshFromOtherCopies()
        return try entries(admittedBy: query, verb: .list).map(summary)
    }

    func groups() throws -> [GroupSummary] {
        let smartGroups = try readSmartGroups(verb: .groups)
        let context = library.sidebarContext
        let subjects = library.entries.map { (entry: $0, subject: context.subject(of: $0)) }
        return smartGroups.map { group in
            GroupSummary(
                id: group.id, name: group.name, kind: .smartGroup,
                members: subjects.filter { group.filter.admits($0.subject) }.map { summary($0.entry) })
        }
    }

    // MARK: - Resolution

    /// The library entries `query` admits, in its order: each one `query`'s
    /// filter admits, on one of its named networks when it names any, and in
    /// every group it names.
    ///
    /// - Throws: ``CommandError/itemNotFoundOnHost(item:)`` for a network or
    ///   group name the library lists none by.
    func entries(admittedBy query: VMListQuery, verb: VMVerb) throws -> [LibraryEntry] {
        var filter = query.filter
        if !query.networkNames.isEmpty { library.networks.reload() }
        for name in query.networkNames {
            let network = try library.networks.requireNetwork(named: name)
            filter.networks.insert(
                VMLibraryFilter.Network(.vmnet(network.kind, .network(network.id))) { _, _ in true })
        }
        let groups = try query.groups.map { try membership(of: $0, verb: verb) }
        let context = library.sidebarContext
        let admitted = library.entries.filter { entry in
            let subject = context.subject(of: entry)
            return filter.admits(subject) && groups.allSatisfy { $0(entry, subject) }
        }
        return query.sort.ordered(admitted)
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
