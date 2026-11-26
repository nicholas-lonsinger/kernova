import Foundation
import KernovaKit

/// What a ``NamedList`` holds: one of a virtual machine's snapshots, storage
/// disks or shared directories, which a door names by text among its
/// siblings.
package protocol ListNamed: Equatable, Sendable {
    var id: UUID { get }
    /// The name the list keeps this element's own among its siblings.
    var listedName: String { get set }
    /// What the element is named from when its own name is empty or spells
    /// an identifier — well formed, or so once a count follows it.
    var nameBase: String { get }
    /// What a door reads as one of these elements' identifiers rather than as
    /// a name.
    static var identifiers: NameRule.Identifiers { get }
}

/// A list of a virtual machine's elements a door names — its snapshots, its
/// storage disks, its shared directories — in which every element's name is
/// its own (``NameRule``).
///
/// Held by construction. Built from elements or decoded from a file, the
/// list gives each name that is malformed, or one name with an earlier
/// element's, the first free one in list order
/// (``NameRule/assignment(of:identifiers:fallback:)``): a pure function of
/// the list, so every copy of Kernova reading one file agrees without a
/// write, and the file's next commit stores the repair. After that, only
/// ``append(_:)`` and ``insert(_:at:)`` — the first free name from the
/// element's own — and ``rename(_:to:)`` — a name a caller chose, refused
/// where it can't be one — give a name.
package struct NamedList<Element: ListNamed>: Equatable, Sendable {
    package private(set) var elements: [Element]

    package init() {
        elements = []
    }

    /// `elements` in their order, each under the name
    /// ``NameRule/assignment(of:identifiers:fallback:)`` gives it.
    package init(repairing elements: some Sequence<Element>) {
        let stored = Array(elements)
        let names = NameRule.assignment(of: stored.map(\.listedName), identifiers: Element.identifiers) {
            stored[$0].nameBase
        }
        self.elements = zip(stored, names).map { element, name in
            var element = element
            element.listedName = name
            return element
        }
    }

    /// The names every element but the one `id` identifies goes by.
    package func names(excluding id: UUID?) -> [String] {
        elements.filter { $0.id != id }.map(\.listedName)
    }

    /// `proposed` as the name of the element `id` identifies — or of a new
    /// one, for `nil` — beside every other
    /// (``NameRule/validated(_:among:identifiers:)``).
    package func validatedName(_ proposed: String, for id: UUID?) throws(NameRule.Refusal) -> String {
        try NameRule.validated(proposed, among: names(excluding: id), identifiers: Element.identifiers)
    }

    /// The name Kernova gives `element` joining the list: its own, where that
    /// is well formed and free, else the first free one counted from it, or
    /// from its ``ListNamed/nameBase``.
    package func freeName(for element: Element) -> String {
        NameRule.name(
            for: element.listedName, fallback: element.nameBase, among: names(excluding: nil),
            identifiers: Element.identifiers)
    }

    /// Appends `element` under the name Kernova gives it (``freeName(for:)``).
    package mutating func append(_ element: Element) {
        insert(element, at: elements.endIndex)
    }

    /// Inserts `element` at `index` under the name Kernova gives it
    /// (``freeName(for:)``), so an element already listed keeps its own.
    package mutating func insert(_ element: Element, at index: Int) {
        var element = element
        element.listedName = freeName(for: element)
        elements.insert(element, at: index)
    }

    /// Renames the element `id` identifies to `proposed`, refusing a name
    /// ``validatedName(_:for:)`` refuses; a no-op for an element the list
    /// does not hold.
    package mutating func rename(_ id: UUID, to proposed: String) throws(NameRule.Refusal) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[index].listedName = try validatedName(proposed, for: id)
    }

    /// Applies `change` to the element `id` identifies, keeping its name,
    /// which only ``rename(_:to:)`` changes; a no-op for an element the list
    /// does not hold.
    package mutating func update(_ id: UUID, _ change: (inout Element) -> Void) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        let name = elements[index].listedName
        change(&elements[index])
        elements[index].listedName = name
    }

    /// Removes every element `shouldRemove` answers true for.
    package mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        elements.removeAll(where: shouldRemove)
    }

    /// Puts the elements in the order `areInIncreasingOrder` sorts them,
    /// elements it ranks alike keeping their order.
    package mutating func reorder(by areInIncreasingOrder: (Element, Element) -> Bool) {
        elements = elements.enumerated()
            .sorted { left, right in
                if areInIncreasingOrder(left.element, right.element) { return true }
                if areInIncreasingOrder(right.element, left.element) { return false }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}

extension NamedList: RandomAccessCollection {
    package var startIndex: Int { elements.startIndex }
    package var endIndex: Int { elements.endIndex }

    package subscript(position: Int) -> Element {
        elements[position]
    }
}

extension NamedList: ExpressibleByArrayLiteral {
    /// The list ``init(repairing:)`` makes of `elements`.
    package init(arrayLiteral elements: Element...) {
        self.init(repairing: elements)
    }
}

extension NamedList: Codable where Element: Codable {
    /// The list the file holds, as ``init(repairing:)`` makes it.
    package init(from decoder: any Decoder) throws {
        self.init(repairing: try decoder.singleValueContainer().decode([Element].self))
    }

    /// The elements, as a list.
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}
