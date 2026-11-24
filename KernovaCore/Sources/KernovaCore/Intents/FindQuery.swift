import AppIntents
import Foundation
import KernovaCommandModel

/// A property query whose Find action Kernova runs: Kernova filters, sorts
/// and truncates what the action answers.
///
/// None is an `EnumerableEntityQuery`, whose entities Shortcuts filters
/// itself, as that protocol's documentation says. On macOS 27.2, Shortcuts
/// filtered a query adopting both protocols itself too, and never called
/// `entities(matching:mode:sortedBy:limit:)`.
///
/// Each conformer spells `properties` and `sortingOptions` as stored
/// properties with an inline builder, the only shape the App Intents metadata
/// processor parses: a computed property returning the same value exports no
/// metadata, which leaves the filters and sorts silently absent from
/// Shortcuts. They are `nonisolated(unsafe)` because AppIntents' builder
/// results are not marked `Sendable`; each is built once from constant
/// closures and never mutated.
protocol FindQuery: EntityPropertyQuery {
    /// `entities`, in the order the query reads them, ordered by the property
    /// `key` names; one naming a property this query does not offer to sort
    /// on leaves them as given.
    static func sorted(_ entities: [Entity], by key: PartialKeyPath<Entity>, ascending: Bool) -> [Entity]
}

/// One condition a Find puts on the entities it answers, judged of each
/// entity alone.
typealias FindPredicate<Entity> = @Sendable (Entity) -> Bool

extension FindQuery {
    /// The sort and truncation a Find asks of `entities`, given in the order
    /// the query reads them.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for a negative `limit`,
    ///   which the framework types as any `Int` and `prefix` traps on.
    static func ordered(
        _ entities: [Entity], by sortedBy: [EntityQuerySort<Entity>], limit: Int?
    ) throws -> [Entity] {
        let ordered = sortedBy.first.map { sorted(entities, by: $0.by, ascending: $0.order == .ascending) } ?? entities
        guard let limit else { return ordered }
        guard limit >= 0 else {
            throw CommandError.invalidArgument("A Find\u{2019}s limit is a number of results, not \(limit).")
        }
        return Array(ordered.prefix(limit))
    }

    /// `entities` in ``VMLibrarySort/name``'s order of the names `name`
    /// reads, or, not `ascending`, that order reversed.
    static func sorted(byName entities: [Entity], _ name: (Entity) -> String, ascending: Bool) -> [Entity] {
        let ordered = VMLibrarySort.name.ordered(entities) {
            VMLibrarySort.Keys(name: name($0), createdAt: nil, lastRun: .unrecorded)
        }
        return ascending ? ordered : ordered.reversed()
    }
}
