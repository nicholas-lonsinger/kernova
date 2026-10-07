import Foundation
import KernovaKit

/// The library's smart groups, changed through ``organization`` — each change
/// followed by the selection moving onto what the sidebar then lists.
extension VMLibrary {
    /// Every smart group, in the order the sidebar lists them.
    var smartGroups: [VMSmartGroup] { organization.smartGroups }

    /// Saves the library section's filter as a smart group named `name`, then
    /// clears that filter: the group lists what the filter did, and the
    /// library every VM.
    @discardableResult
    func saveSidebarFilterAsSmartGroup(named name: String) throws -> VMSmartGroup {
        let group = try organization.createSmartGroup(named: name, filter: sidebarOptions.filter)
        sidebarOptions.filter = VMLibraryFilter()
        return group
    }

    /// Makes the smart group `id` identifies list what `filter` admits.
    func setFilter(_ filter: VMLibraryFilter, ofSmartGroup id: UUID) throws {
        try organization.setFilter(filter, ofSmartGroup: id)
        reconcileSelection()
    }

    /// Renames the smart group `id` identifies.
    func renameSmartGroup(_ id: UUID, to name: String) throws {
        try organization.renameSmartGroup(id, to: name)
    }

    /// Deletes the smart group `id` identifies; a VM selected in it stays
    /// selected in the library section.
    func deleteSmartGroup(_ id: UUID) throws {
        try organization.removeSmartGroup(id)
        reconcileSelection()
    }

    /// Drops the named network `id`, which is being deleted, from every
    /// filter naming it — each smart group's and the library section's.
    func removeNetworkFromFilters(_ id: UUID) throws {
        try organization.removeNetwork(id)
        sidebarOptions.filter = sidebarOptions.filter.removingNetwork(id)
        reconcileSelection()
    }
}
