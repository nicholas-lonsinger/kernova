import Foundation
import KernovaLogging

/// The library's folders, changed through ``organization`` — each change
/// that can take a row out of the sidebar followed by the selection moving
/// onto what the sidebar then lists.
///
/// A folder section lists only the members the library holds
/// (``SidebarLayout``), so an identifier no entry carries is listed nowhere.
/// An entry leaving the library while it runs leaves every folder
/// (``leaveEveryFolder(_:)``); one that left unseen — its bundle trashed with
/// Kernova closed — keeps its identifier there, and a VM coming back under
/// it is listed in those folders again, whichever way it returns.
extension VMLibrary {
    /// Every folder, in the order the sidebar lists them.
    var folders: [VMFolder] { organization.folders }

    /// Lists a new folder named `name` holding `members`.
    @discardableResult
    func createFolder(named name: String, members: [UUID] = []) throws -> VMFolder {
        try organization.createFolder(named: name, members: members.filter(holdsEntry))
    }

    /// Renames the folder `id` identifies.
    func renameFolder(_ id: UUID, to name: String) throws {
        try organization.renameFolder(id, to: name)
    }

    /// Deletes the folder `id` identifies, keeping every VM it held; a VM
    /// selected in it stays selected in the library section.
    func deleteFolder(_ id: UUID) throws {
        try organization.removeFolder(id)
        reconcileSelection()
    }

    /// Moves the folder `id` identifies to just before the one `successor`
    /// identifies, or after every other when `successor` is `nil`.
    func moveFolder(_ id: UUID, before successor: UUID?) throws {
        try organization.moveFolder(id, before: successor)
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

    /// Takes the entry `id` out of every folder, as it leaves the library.
    ///
    /// A failed write leaves the identifier listed in the file, where no
    /// section shows it while the library lists no entry under it; it is
    /// logged rather than presented, since the change the user asked for —
    /// the delete, the cancel — went through.
    func leaveEveryFolder(_ id: UUID) {
        do {
            try organization.removeFromEveryFolder([id])
        } catch {
            #log(
                Self.logger, .error,
                "Couldn't take \(id.uuidString, privacy: .public) out of the library's folders: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func holdsEntry(_ id: UUID) -> Bool {
        entries.contains { $0.id == id }
    }
}
