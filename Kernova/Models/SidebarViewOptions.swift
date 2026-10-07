import Foundation
import KernovaKit

/// How the sidebar's library section narrows, orders and groups the library.
///
/// A projection only: the library's own order — ``VMLibrary/entries``, the
/// status menu, `kernova list` — stays the manual one whatever these say.
struct SidebarViewOptions: Codable, Hashable, Sendable {
    var filter = VMLibraryFilter()
    var sort: VMLibrarySort = .manual
    var grouping: SidebarGrouping = .none
    /// Whether each row carries a second line stating its sort key's value.
    var showsDetails = false
}

extension LibraryEntry {
    /// What a ``VMLibrarySort`` reads of this entry.
    var sortKeys: VMLibrarySort.Keys {
        VMLibrarySort.Keys(name: name, createdAt: configuration.createdAt)
    }
}

extension VMLibrarySort {
    /// `entries` in this order; entries the key ties keep their manual order.
    @MainActor
    func ordered(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        ordered(entries, by: \.sortKeys)
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
