import Foundation
import KernovaKit
import KernovaLogging

/// How the library is organized beyond its VMs — its smart groups and
/// folders — and the one writer of the file that holds it.
@MainActor
@Observable
final class VMOrganizationDirectory {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMOrganizationDirectory")

    /// Where the library every copy of the app shares keeps its organization,
    /// beside the folder its VMs live in.
    nonisolated static let productionFileURL = URL.applicationSupportDirectory
        .appendingPathComponent("Kernova", isDirectory: true)
        .appendingPathComponent("Organization.json", isDirectory: false)

    /// The file's payload.
    struct File: Codable, Equatable, Sendable {
        /// In the order the sidebar lists them.
        var smartGroups: [VMSmartGroup]
        /// In the order the sidebar lists them.
        var folders: [VMFolder]

        init(smartGroups: [VMSmartGroup] = [], folders: [VMFolder] = []) {
            self.smartGroups = smartGroups
            self.folders = folders
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            smartGroups = try container.decode([VMSmartGroup].self, forKey: .smartGroups)
            folders = try container.decodeIfPresent([VMFolder].self, forKey: .folders) ?? []
        }
    }

    /// What a name names, which its refusals say.
    enum Kind: Sendable, Equatable {
        case smartGroup
        case folder

        var noun: String {
            switch self {
            case .smartGroup: "smart group"
            case .folder: "folder"
            }
        }
    }

    /// Why a change to the organization was refused.
    enum ChangeError: LocalizedError, Equatable {
        case nameRequired(Kind)
        case nameTaken(String, Kind)
        case nameIsIdentifier(String, Kind)
        case unreadable(String)
        case unsaved(String)

        var errorDescription: String? {
            switch self {
            case .nameRequired(let kind):
                "A \(kind.noun) needs a name."
            case .nameTaken(let name, let kind):
                "A \(kind.noun) named \u{201C}\(name)\u{201D} already exists. Give this one another name."
            case .nameIsIdentifier(let name, let kind):
                "\u{201C}\(name)\u{201D} can\u{2019}t name a \(kind.noun): an identifier already names one."
            case .unreadable(let reason):
                "Kernova couldn\u{2019}t read its smart groups and folders, so it changes none: \(reason)"
            case .unsaved(let reason):
                "Kernova couldn\u{2019}t save its smart groups and folders: \(reason)"
            }
        }
    }

    /// Every smart group, in the order the sidebar lists them.
    private(set) var smartGroups: [VMSmartGroup] = []

    /// Every folder, in the order the sidebar lists them.
    private(set) var folders: [VMFolder] = []

    /// Why the file could not be read the last time, `nil` when it was, or
    /// holds nothing yet. A change reads the file again first and refuses
    /// when that read fails, so an unread file is never overwritten.
    private(set) var readFailure: String?

    /// The file the organization persists in, `nil` to keep it in memory only.
    @ObservationIgnored private let file: CoordinatedJSONFile<File>?

    /// The organization `fileURL` holds — none when there is no file yet.
    init(fileURL: URL?) {
        self.file = fileURL.map { CoordinatedJSONFile(url: $0, empty: File()) }
        reload()
    }

    /// Reads the file again, taking in what another copy of Kernova sharing
    /// the library wrote since.
    func reload() {
        guard let file else { return }
        do {
            show(try file.read())
            readFailure = nil
        } catch {
            let reason = error.reason
            readFailure = reason
            #log(
                Self.logger, .error,
                "Couldn't read the library organization at \(file.url.path(percentEncoded: false), privacy: .public): \(reason, privacy: .public)"
            )
        }
    }

    /// Lists what `read` holds, assigning only the lists that changed so an
    /// observer of one is not told about the other.
    private func show(_ read: File) {
        if read.smartGroups != smartGroups { smartGroups = read.smartGroups }
        if read.folders != folders { folders = read.folders }
    }

    // MARK: - Reads

    /// The smart group `id` identifies, `nil` when the library lists none.
    func smartGroup(withID id: UUID) -> VMSmartGroup? {
        smartGroups.first { $0.id == id }
    }

    /// The folder `id` identifies, `nil` when the library lists none.
    func folder(withID id: UUID) -> VMFolder? {
        folders.first { $0.id == id }
    }

    /// The smart group `text` names — by identifier, or by name ignoring case
    /// — `nil` when the library lists none.
    func smartGroup(named text: String) -> VMSmartGroup? {
        Self.element(named: text, in: smartGroups, name: \.name)
    }

    /// The folder `text` names — by identifier, or by name ignoring case —
    /// `nil` when the library lists none.
    func folder(named text: String) -> VMFolder? {
        Self.element(named: text, in: folders, name: \.name)
    }

    private static func element<Element: Identifiable<UUID>>(
        named text: String, in elements: [Element], name: (Element) -> String
    ) -> Element? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let element = elements.first(where: { $0.id == id }) {
            return element
        }
        return elements.first { name($0).caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// `base`, or the first of "`base` 2", "`base` 3", … no `kind` is named —
    /// what a new one's name field starts from.
    func unusedName(from base: String, for kind: Kind) -> String {
        let names =
            switch kind {
            case .smartGroup: smartGroups.map(\.name)
            case .folder: folders.map(\.name)
            }
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Smart groups

    /// Lists a new smart group named `name` showing what `filter` admits,
    /// after every other.
    @discardableResult
    func createSmartGroup(named name: String, filter: VMLibraryFilter) throws -> VMSmartGroup {
        var created: VMSmartGroup?
        try commit { file in
            let group = VMSmartGroup(
                id: UUID(),
                name: try Self.validatedName(
                    name, of: .smartGroup, for: nil, among: file.smartGroups.map { ($0.id, $0.name) }),
                filter: filter)
            created = group
            file.smartGroups.append(group)
        }
        guard let created else { preconditionFailure("A committed create made no smart group") }
        return created
    }

    /// Renames the smart group `id` identifies.
    func renameSmartGroup(_ id: UUID, to name: String) throws {
        try commit { file in
            let name = try Self.validatedName(
                name, of: .smartGroup, for: id, among: file.smartGroups.map { ($0.id, $0.name) })
            Self.edit(id, in: &file.smartGroups) { $0.name = name }
        }
    }

    /// Makes the smart group `id` identifies show what `filter` admits.
    func setFilter(_ filter: VMLibraryFilter, ofSmartGroup id: UUID) throws {
        try commit { file in Self.edit(id, in: &file.smartGroups) { $0.filter = filter } }
    }

    /// Drops the named network `id` from every smart group's filter.
    func removeNetwork(_ id: UUID) throws {
        try commit { file in
            for index in file.smartGroups.indices {
                file.smartGroups[index].filter = file.smartGroups[index].filter.removingNetwork(id)
            }
        }
    }

    /// Stops listing the smart group `id` identifies.
    func removeSmartGroup(_ id: UUID) throws {
        try commit { file in file.smartGroups.removeAll { $0.id == id } }
    }

    /// Moves the smart group `id` identifies to just before the one `successor`
    /// identifies, or after every other when `successor` is `nil` or no longer
    /// listed.
    func moveSmartGroup(_ id: UUID, before successor: UUID?) throws {
        try commit { file in Self.move(id, before: successor, in: &file.smartGroups, by: \.id) }
    }

    // MARK: - Folders

    /// Lists a new folder named `name` holding `members`, after every other.
    @discardableResult
    func createFolder(named name: String, members: [UUID] = []) throws -> VMFolder {
        var created: VMFolder?
        try commit { file in
            let folder = VMFolder(
                id: UUID(),
                name: try Self.validatedName(name, of: .folder, for: nil, among: file.folders.map { ($0.id, $0.name) }),
                members: Self.unique(members))
            created = folder
            file.folders.append(folder)
        }
        guard let created else { preconditionFailure("A committed create made no folder") }
        return created
    }

    /// Renames the folder `id` identifies.
    func renameFolder(_ id: UUID, to name: String) throws {
        try commit { file in
            let name = try Self.validatedName(name, of: .folder, for: id, among: file.folders.map { ($0.id, $0.name) })
            Self.edit(id, in: &file.folders) { $0.name = name }
        }
    }

    /// Stops listing the folder `id` identifies; its VMs stay in the library.
    func removeFolder(_ id: UUID) throws {
        try commit { file in file.folders.removeAll { $0.id == id } }
    }

    /// Moves the folder `id` identifies to just before the one `successor`
    /// identifies, or after every other when `successor` is `nil` or no longer
    /// listed.
    func moveFolder(_ id: UUID, before successor: UUID?) throws {
        try commit { file in Self.move(id, before: successor, in: &file.folders, by: \.id) }
    }

    /// Puts each of `entries` the folder `id` identifies does not hold yet
    /// after its members, in `entries`' order.
    func add(_ entries: [UUID], toFolder id: UUID) throws {
        try commit { file in
            Self.edit(id, in: &file.folders) { $0.members = Self.unique($0.members + entries) }
        }
    }

    /// Takes the entry `entry` out of the folder `id` identifies.
    func remove(_ entry: UUID, fromFolder id: UUID) throws {
        try commit { file in Self.edit(id, in: &file.folders) { $0.members.removeAll { $0 == entry } } }
    }

    /// Moves the member `entry` of the folder `id` identifies to just before
    /// the member `successor`, or after every other when `successor` is `nil`
    /// or no longer a member.
    func move(_ entry: UUID, before successor: UUID?, inFolder id: UUID) throws {
        try commit { file in
            Self.edit(id, in: &file.folders) { Self.move(entry, before: successor, in: &$0.members, by: \.self) }
        }
    }

    /// Takes each of `entries` out of every folder.
    func removeFromEveryFolder(_ entries: Set<UUID>) throws {
        try commit { file in
            for index in file.folders.indices {
                file.folders[index].members.removeAll(where: entries.contains)
            }
        }
    }

    // MARK: - Commit

    /// `name` trimmed, refusing an empty one, one spelling an identifier, and
    /// one an element of `named` other than `id` holds, ignoring case — what
    /// lets a name select one.
    private static func validatedName(
        _ name: String, of kind: Kind, for id: UUID?, among named: [(id: UUID, name: String)]
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChangeError.nameRequired(kind) }
        guard UUID(uuidString: trimmed) == nil else { throw ChangeError.nameIsIdentifier(trimmed, kind) }
        if let other = named.first(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            throw ChangeError.nameTaken(other.name, kind)
        }
        return trimmed
    }

    /// Applies `change` to the element of `list` that `id` identifies, if any.
    private static func edit<Element: Identifiable>(
        _ id: Element.ID, in list: inout [Element], _ change: (inout Element) -> Void
    ) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
    }

    /// Moves the element `key` names to just before the one `successor`
    /// names, or to the end when `successor` is `nil` or not in `list`.
    private static func move<Element, Key: Equatable>(
        _ key: Key, before successor: Key?, in list: inout [Element], by keyPath: KeyPath<Element, Key>
    ) {
        guard key != successor, let from = list.firstIndex(where: { $0[keyPath: keyPath] == key }) else {
            return
        }
        let moved = list.remove(at: from)
        let to = successor.flatMap { next in list.firstIndex { $0[keyPath: keyPath] == next } } ?? list.endIndex
        list.insert(moved, at: to)
    }

    /// `ids` with every repeat after the first dropped.
    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Applies `change` to what the file holds now and writes the result
    /// (``CoordinatedJSONFile/update(_:)``), then lists the result.
    private func commit(_ change: (inout File) throws -> Void) throws {
        func changed(_ current: File) throws -> File {
            var next = current
            try change(&next)
            return next
        }
        guard let file else {
            show(try changed(File(smartGroups: smartGroups, folders: folders)))
            return
        }
        do {
            show(try file.update(changed))
        } catch let failure as CoordinatedJSONFile<File>.Failure {
            switch failure {
            case .unreadable: throw ChangeError.unreadable(failure.reason)
            case .unsaved: throw ChangeError.unsaved(failure.reason)
            }
        }
        readFailure = nil
    }
}
