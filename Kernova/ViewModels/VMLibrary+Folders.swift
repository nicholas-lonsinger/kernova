import Foundation

/// The library's folders, changed through ``organization`` — each change
/// that can take a row out of the sidebar followed by the selection moving
/// onto what the sidebar then lists.
///
/// A folder section lists only the members the library holds
/// (``SidebarLayout``), so an identifier no entry carries is listed nowhere.
/// An entry leaving the library keeps its identifier in its folders, however
/// it leaves, and a VM coming back under it is listed in them again, however
/// it returns.
extension VMLibrary {
    /// Every folder, in the order the sidebar lists them; `nil` while the
    /// file holding them can't be read.
    var folders: [VMFolder]? { organization.folders }

    /// Lists a new folder named `name` holding `members`.
    @discardableResult
    func createFolder(named name: String, members: [UUID] = []) throws -> VMFolder {
        try organization.createFolder(named: name, members: members.filter(holdsEntry))
    }

    /// Renames the folder `id` identifies.
    func renameFolder(_ id: UUID, to name: String) throws {
        try organization.renameFolder(id, to: name)
    }

    /// Deletes the folder `id` identifies, and its saved collapsed state,
    /// keeping every VM it held; a VM selected in it stays selected in the
    /// library section.
    func deleteFolder(_ id: UUID) throws {
        try organization.removeFolder(id)
        forgetCollapsed(.folder(id))
        reconcileSelection()
    }

    /// Adds each of `entries` the library lists to the folder `id`
    /// identifies, after its members.
    func add(_ entries: [UUID], toFolder id: UUID) throws {
        try organization.add(entries.filter(holdsEntry), toFolder: id)
    }

    /// Takes the entry `entry` out of the folder `id` identifies; selected in
    /// that folder, it stays selected in the library section.
    func remove(_ entry: UUID, fromFolder id: UUID) throws {
        try organization.remove(entry, fromFolder: id)
        reconcileSelection()
    }

    /// Moves the member `entry` of the folder `id` identifies to just before
    /// the member `successor`, or after every other when `successor` is `nil`.
    func move(_ entry: UUID, before successor: UUID?, inFolder id: UUID) throws {
        try organization.move(entry, before: successor, inFolder: id)
    }

    private func holdsEntry(_ id: UUID) -> Bool {
        entries.contains { $0.id == id }
    }
}
