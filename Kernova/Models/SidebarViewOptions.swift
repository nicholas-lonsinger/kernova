import Foundation
import KernovaKit

/// How the sidebar's library section narrows, orders and groups the library.
///
/// A projection only: the library's own order — ``VMLibrary/entries``, the
/// status menu, `kernova list` — stays the manual one whatever these say.
struct SidebarViewOptions: Codable, Hashable, Sendable {
    var filter = VMLibraryFilter()
    var sort: SidebarSort = .manual
    var grouping: SidebarGrouping = .none
    /// Whether each row carries a second line stating its sort key's value.
    var showsDetails = false
}

/// The order the library section lists its rows in. Each key has one fixed
/// direction.
enum SidebarSort: String, Codable, CaseIterable, Sendable {
    /// A→Z.
    case name
    /// Newest first.
    case dateCreated
    /// The library's own order, or a folder's own in its section — the
    /// order dragging a row there changes.
    case manual

    var title: String {
        switch self {
        case .name: "Name"
        case .dateCreated: "Date Created"
        case .manual: "Manual"
        }
    }

    /// `entries` in this order; entries the key ties keep their manual order.
    @MainActor
    func ordered(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        let precedes: (LibraryEntry, LibraryEntry) -> Bool? =
            switch self {
            case .manual: { _, _ in nil }
            case .name:
                { lhs, rhs in
                    switch lhs.name.localizedStandardCompare(rhs.name) {
                    case .orderedAscending: true
                    case .orderedDescending: false
                    case .orderedSame: nil
                    }
                }
            case .dateCreated:
                { lhs, rhs in
                    let left = lhs.configuration.createdAt
                    let right = rhs.configuration.createdAt
                    return left == right ? nil : left > right
                }
            }
        return entries.enumerated()
            .sorted { lhs, rhs in precedes(lhs.element, rhs.element) ?? (lhs.offset < rhs.offset) }
            .map(\.element)
    }

    /// The second line a row shows under this key: the value it is ordered by,
    /// or its status where the order is by name or by hand.
    @MainActor
    func detail(for entry: LibraryEntry) -> String {
        switch self {
        case .name, .manual:
            switch entry {
            case .vm(let instance):
                instance.status.displayName(heldByAnotherCopy: instance.heldByAnotherCopy)
            case .arriving(let arrival):
                arrival.displayLabel
            }
        case .dateCreated:
            "Created \(entry.configuration.createdAt.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

/// The headers the library section lists its rows under.
enum SidebarGrouping: String, Codable, CaseIterable, Sendable {
    case none
    case guestOS
    case state
    case network

    var title: String {
        switch self {
        case .none: "None"
        case .guestOS: "Guest OS"
        case .state: "State"
        case .network: "Network"
        }
    }
}
