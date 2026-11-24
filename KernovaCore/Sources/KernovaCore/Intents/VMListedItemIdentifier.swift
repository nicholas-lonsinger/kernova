import AppIntents
import Foundation

/// How Shortcuts persists the identifier of one item a VM lists — a snapshot,
/// a shared directory, a remembered USB accessory: the VM, then the item as
/// that VM's list names it, joined by `/`.
///
/// Shortcuts hands a saved identifier back to its query's `entities(for:)`,
/// which can run with no intent parameter bound, so the identifier has to
/// carry the VM whose list to read. A VM identifier holds no `/`, so the first
/// one splits the two however many the item holds.
enum VMListedItemIdentifier {
    /// The string `item` on the VM `vm` persists as.
    static func string(vm: UUID, item: String) -> String {
        "\(vm.uuidString)/\(item)"
    }

    /// The VM and the item `string` names, `nil` for one this never wrote.
    static func parts(of string: String) -> (vm: UUID, item: String)? {
        let halves = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2, let vm = UUID(uuidString: String(halves[0])) else { return nil }
        return (vm, String(halves[1]))
    }

    /// The entities `identifiers` name, in the order named, each read from the
    /// list `listing` answers for the VM `vm` says it carries — what a query
    /// over a VM's items answers for saved identifiers.
    ///
    /// A VM that has since left the library drops its identifiers rather than
    /// failing the whole resolution, the way a saved VM reference does; the
    /// gateway has already logged that refusal.
    static func entities<Entity: AppEntity>(
        _ identifiers: [Entity.ID], vm: (Entity.ID) -> UUID,
        listing: (UUID) async throws -> [Entity]
    ) async -> [Entity] {
        var found: [Entity.ID: Entity] = [:]
        for owner in Set(identifiers.map(vm)) {
            for entity in (try? await listing(owner)) ?? [] {
                found[entity.id] = entity
            }
        }
        return identifiers.compactMap { found[$0] }
    }
}
