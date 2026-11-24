import Foundation
import KernovaCommandModel

/// One change to which rows the library holds or what one is named, for a
/// reader that keeps its own record of the library (``VMCommandCore/events()``).
enum VMLibraryEvent: Sendable, Hashable {
    /// A row entered the library — created, cloned, imported, or found on disk.
    case added(VMSummary)
    /// A row left the library.
    case removed(id: UUID, name: String)
    /// A row's display name changed.
    case renamed(id: UUID, from: String, to: String)
}
