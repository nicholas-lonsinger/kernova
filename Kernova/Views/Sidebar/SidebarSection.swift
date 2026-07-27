import Foundation

/// A top-level group in the sidebar's source list (e.g. "Virtual Machines").
///
/// `NSOutlineView` keys items on object identity, so sections are long-lived
/// reference instances held by the controller; the shared `id` is also the key
/// for expansion-state autosave.
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
