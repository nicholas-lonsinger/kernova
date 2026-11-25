import AppIntents
import Foundation
import KernovaCommandModel

/// A property query whose Find action Kernova runs: Kernova filters, sorts
/// and truncates what the action answers.
///
/// A conformer adopts no `EnumerableEntityQuery`, whose entities Shortcuts
/// filters itself, as that protocol's documentation says. On macOS 27.2,
/// Shortcuts filtered a query adopting both protocols itself too, and never
/// called `entities(matching:mode:sortedBy:limit:)`.
protocol FindQuery: EntityPropertyQuery where ComparatorMappingType: FindComparison {
    /// `entities`, in the order the query reads them, ordered by the property
    /// `key` names; one naming a property this query does not offer to sort
    /// on leaves them as given.
    static func sorted(_ entities: [Entity], by key: PartialKeyPath<Entity>, ascending: Bool) -> [Entity]
}

/// What a ``FindQuery``'s comparators map to: a nominal type, never a
/// function type.
///
/// Swift 6.4.2 (Xcode 27B52) accepts converting an array of `@Sendable`
/// functions to an array of the same functions without `@Sendable`, and the
/// runtime traps on the element cast: "Could not cast value of type
/// '@Sendable (Swift.Int) -> Swift.Bool' to '(Swift.Int) -> Swift.Bool'". An
/// array of a nominal type has no such conversion to make.
protocol FindComparison: Sendable {}

/// One condition a Find puts on the entities it answers, judged of each
/// entity alone.
struct FindPredicate<Entity>: FindComparison {
    /// Whether the condition holds for an entity.
    let admits: @Sendable (Entity) -> Bool

    init(_ admits: @escaping @Sendable (Entity) -> Bool) {
        self.admits = admits
    }
}

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

    /// `entities` in ``VMLibrarySort/name``'s order of the text `title`
    /// reads, or, not `ascending`, that order reversed.
    static func sorted(_ entities: [Entity], byTitle title: (Entity) -> String, ascending: Bool) -> [Entity] {
        let ordered = VMLibrarySort.name.ordered(entities) {
            VMLibrarySort.Keys(name: title($0), createdAt: nil, lastRun: .unrecorded)
        }
        return ascending ? ordered : ordered.reversed()
    }
}
