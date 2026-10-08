import Foundation
import KernovaKit

/// The library's smart groups, changed through ``organization`` — each change
/// followed by the selection moving onto what the sidebar then lists.
extension VMLibrary {
    /// Every smart group, in the order the sidebar lists them; `nil` while
    /// the file holding them can't be read.
    var smartGroups: [VMSmartGroup]? { organization.smartGroups }

    /// Saves `filter` — the library section's filter as the user was shown
    /// it, which may since have changed — as a smart group named `name`,
    /// then clears the library section's filter: the group lists what the
    /// filter did, and the library every VM.
    @discardableResult
    func saveSidebarFilter(_ filter: VMLibraryFilter, asSmartGroupNamed name: String) throws -> VMSmartGroup {
        let group = try organization.createSmartGroup(named: name, filter: filter)
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

    /// Deletes the smart group `id` identifies, and its saved collapsed state;
    /// a VM selected in it stays selected in the library section.
    func deleteSmartGroup(_ id: UUID) throws {
        try organization.removeSmartGroup(id)
        forgetCollapsed(.smartGroup(id))
        reconcileSelection()
    }
}
