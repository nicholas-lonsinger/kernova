import Foundation

/// A top-level group in the sidebar's source list (e.g. "Virtual Machines").
///
/// The sidebar is a two-level `NSOutlineView`: `SidebarSection`s are the
/// group rows and their children are the leaf rows. Today there is a single
/// section, but the type exists so adding a second group later (e.g.
/// "Containers") is a localized change — add another instance and a case to
/// the controller's child-resolution. `NSOutlineView` keys items on object
/// identity, so sections are long-lived reference instances held by the
/// controller; the shared `id` is also the key for expansion-state autosave.
///
/// `Sendable` (immutable `let` storage) so the `virtualMachines` singleton is
/// a concurrency-safe global under Swift 6 strict concurrency.
final class SidebarSection: Sendable {
    /// Stable identifier used as the outline expansion-state autosave key.
    let id: String

    /// Header text shown on the group row.
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// The sole section today: the list of virtual machines.
    static let virtualMachines = SidebarSection(id: "virtualMachines", title: "Virtual Machines")
}
