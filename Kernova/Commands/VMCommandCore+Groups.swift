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
    let groups: [VMGroupMembership]
    /// The order admitted entries are listed in.
    let sort: VMLibrarySort

    /// Every entry, in library order.
    static let all = VMLibrarySelection(filter: VMLibraryFilter(), groups: [], sort: .manual)

    /// The manual order: the first folder's own, else the library's.
    var manualOrder: [UUID]? { groups.lazy.compactMap(\.order).first }
}

/// Which entries one group holds, and the order it holds them in when it has
/// one of its own.
@MainActor
struct VMGroupMembership {
    /// Whether an entry, reading as `subject`, is in the group.
    let contains: (_ entry: LibraryEntry, _ subject: VMLibraryFilter.Subject) -> Bool
    /// The group's own order of its members, `nil` for a group with none.
    let order: [UUID]?
}

/// One group of the library's, resolved from what a caller named it by.
@MainActor
struct VMResolvedGroup {
    let kind: VMGroupKind
    let id: UUID
    let name: String
    let membership: VMGroupMembership

    /// The entries this group holds, in its order: the folder's own, else the
    /// library's.
    var selection: VMLibrarySelection {
        VMLibrarySelection(filter: VMLibraryFilter(), groups: [membership], sort: .manual)
    }
}

extension VMResolvedGroup {
    /// The group `reference` names in `organization`, `nil` for one it does
    /// not list.
    init?(_ reference: VMGroupReference, in organization: VMOrganizationDirectory.File) {
        switch reference.kind {
        case .smartGroup:
            guard let group = organization.smartGroup(named: reference.name) else { return nil }
            self.init(
                kind: .smartGroup, id: group.id, name: group.name,
                membership: VMGroupMembership(contains: { _, subject in group.filter.admits(subject) }, order: nil))
        case .folder:
            guard let folder = organization.folder(named: reference.name) else { return nil }
            let members = Set(folder.members)
            self.init(
                kind: .folder, id: folder.id, name: folder.name,
                membership: VMGroupMembership(
                    contains: { entry, _ in members.contains(entry.id) }, order: folder.members))
        }
    }
}

/// The listing and the library's groups: which VMs a filter, a network, a
/// tag or a group admits, by the same subjects and the same filter the
/// sidebar lists them by.
extension VMCommandCore {
    // MARK: - Reads

    func list(_ selection: VMLibrarySelection) -> [VMSummary] {
        library.refreshFromOtherCopies()
        return entries(in: selection).map(summary)
    }

    func groups() throws -> [GroupSummary] {
        library.refreshFromOtherCopies()
        let organization = try readOrganization(verb: .groups)
        let named: [(id: UUID, name: String, kind: VMGroupKind)] =
            organization.smartGroups.map { ($0.id, $0.name, .smartGroup) }
            + organization.folders.map { ($0.id, $0.name, .folder) }
        return try named.map { group in
            let selection = try self.selection(
                for: VMListQuery(groups: [VMGroupReference(group.kind, named: group.id.uuidString)]),
                verb: .groups)
            return GroupSummary(
                id: group.id, name: group.name, kind: group.kind, members: entries(in: selection).map(summary))
        }
    }

    // MARK: - Resolution

    /// The entries `selection` admits, in its order: each one its filter
    /// admits and in every group it names, under the manual sort in the
    /// order of the folder it names, else the library's. A bundle Kernova
    /// can't read is never one of them.
    func entries(in selection: VMLibrarySelection) -> [AddressableEntry] {
        let context = library.sidebarContext
        let candidates: [LibraryEntry]
        if let order = selection.manualOrder {
            let byID = Dictionary(library.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            candidates = order.compactMap { byID[$0] }
        } else {
            candidates = library.entries
        }
        let admitted = candidates.filter { entry in
            guard let subject = context.subject(of: entry) else { return false }
            return selection.filter.admits(subject) && selection.groups.allSatisfy { $0.contains(entry, subject) }
        }
        return selection.sort.ordered(admitted).compactMap(\.addressable)
    }

    func selection(for query: VMListQuery, verb: VMVerb) throws -> VMLibrarySelection {
        var filter = query.filter
        if !query.networks.isEmpty { library.networks.reload() }
        for text in query.networks {
            filter.networks.insert(try network(spelledBy: text, verb: verb))
        }
        let organization = query.tags.isEmpty ? nil : try readOrganization(verb: verb)
        for text in query.tags {
            guard let tag = organization?.tag(named: text) else {
                throw CommandError.itemNotFoundOnHost(item: "tag named \u{201C}\(text)\u{201D}")
            }
            filter.tags.insert(tag.id)
        }
        return VMLibrarySelection(
            filter: filter, groups: try query.groups.map { try membership(of: $0, verb: verb) },
            sort: query.sort)
    }

    /// The network `text` names as a listing reads it: a mode
    /// (``VMLibraryFilter/Network/init(spelling:)``), or a named network by
    /// name or identifier — either ignoring case. A name no mode spells is
    /// refused as unreadable, not as unknown, while the library's list of
    /// networks can't be read.
    private func network(spelledBy text: String, verb: VMVerb) throws -> VMLibraryFilter.Network {
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
            if library.networks.state.unreadable != nil {
                throw CommandError.operationFailed(verb: verb, message: VMNetworkDirectory.unreadableMessage)
            }
            throw CommandError.itemNotFoundOnHost(item: "network named \u{201C}\(text)\u{201D}")
        }
    }

    /// The group `reference` names, as the library's file holds it now.
    func group(_ reference: VMGroupReference, verb: VMVerb) throws -> VMResolvedGroup {
        try group(reference, in: try readOrganization(verb: verb))
    }

    /// The group `reference` names, as this copy holds the library's
    /// organization in memory — reading no file, for a caller that must not
    /// wait on the disk.
    func heldGroup(_ reference: VMGroupReference, verb: VMVerb) throws -> VMResolvedGroup {
        try group(reference, in: try heldOrganization(verb: verb))
    }

    private func group(
        _ reference: VMGroupReference, in organization: VMOrganizationDirectory.File
    ) throws -> VMResolvedGroup {
        guard let group = VMResolvedGroup(reference, in: organization) else {
            throw CommandError.itemNotFoundOnHost(
                item: "\(reference.kind.noun) named \u{201C}\(reference.name)\u{201D}")
        }
        return group
    }

    /// The entries the group `reference` names holds.
    private func membership(of reference: VMGroupReference, verb: VMVerb) throws -> VMGroupMembership {
        try group(reference, verb: verb).membership
    }

    /// The library's smart groups, folders and tags as their file holds them
    /// now, refusing when the file cannot be read rather than answering none.
    private func readOrganization(verb: VMVerb) throws -> VMOrganizationDirectory.File {
        library.organization.reload()
        return try heldOrganization(verb: verb)
    }

    /// The library's smart groups, folders and tags as this copy holds them in
    /// memory, reading no file — refusing while the last read found the file
    /// unreadable.
    private func heldOrganization(verb: VMVerb) throws -> VMOrganizationDirectory.File {
        switch library.organization.state {
        case .listed(let organization):
            return organization
        case .unreadable:
            throw CommandError.operationFailed(verb: verb, message: VMOrganizationDirectory.unreadableMessage)
        }
    }
}
