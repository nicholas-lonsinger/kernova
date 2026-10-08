import Foundation
import KernovaKit
import KernovaLogging

/// How the library is organized beyond its VMs — its smart groups, folders
/// and tags — and the one writer of the file that holds it.
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

    /// What every surface that cannot list the smart groups, folders or tags
    /// tells the user.
    nonisolated static let unreadableMessage =
        "Kernova can\u{2019}t read its smart groups, folders and tags. Choose File > Check Config Files\u{2026} to review them."

    /// The file's payload: every sidebar section — each smart group, each
    /// folder, and the library exactly once — in the order the sidebar lists
    /// them, and the tags the library defines.
    ///
    /// On disk the smart groups and folders are two lists by kind, and
    /// `sectionOrder` lists every section's ``SidebarSectionID`` in sidebar
    /// order. A section `sectionOrder` does not name follows the ones it does,
    /// smart groups, then folders, each in its list's order, then the library
    /// — every section, for a file with no `sectionOrder`; an identifier no
    /// section carries is ignored.
    struct File: Codable, Equatable, Sendable {
        private(set) var sections: [Section]
        /// In the order every list of them shows them.
        var tags: [VMTag]

        /// Only the library section, and no tags.
        init() {
            sections = [.library]
            tags = []
        }

        var smartGroups: [VMSmartGroup] { sections.compactMap(\.smartGroup) }
        var folders: [VMFolder] { sections.compactMap(\.folder) }

        private enum CodingKeys: String, CodingKey {
            case smartGroups, folders, sectionOrder, tags
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Folders, the section order and tags are lists: an entry that
            // doesn't decode is removed alone, and the rest are kept.
            let byDefault =
                try container.decode([VMSmartGroup].self, forKey: .smartGroups).map(Section.smartGroup)
                + (try container.decode([VMFolder].self, forKey: .folders, default: [], in: decoder))
                .map(Section.folder)
                + [.library]
            let order = try container.decode([SidebarSectionID].self, forKey: .sectionOrder, default: [], in: decoder)
            var rank: [SidebarSectionID: Int] = [:]
            for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
            sections = byDefault.enumerated()
                .sorted { lhs, rhs in
                    (rank[lhs.element.id] ?? order.count, lhs.offset) < (
                        rank[rhs.element.id] ?? order.count, rhs.offset
                    )
                }
                .map(\.element)
            tags = try container.decode([VMTag].self, forKey: .tags, default: [], in: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(smartGroups, forKey: .smartGroups)
            try container.encode(folders, forKey: .folders)
            try container.encode(sections.map(\.id), forKey: .sectionOrder)
            try container.encode(tags, forKey: .tags)
        }

        /// The smart group `text` names — by identifier, or by name ignoring
        /// case — `nil` when the file lists none.
        func smartGroup(named text: String) -> VMSmartGroup? {
            Self.element(named: text, in: smartGroups, name: \.name)
        }

        /// The folder `text` names — by identifier, or by name ignoring case —
        /// `nil` when the file lists none.
        func folder(named text: String) -> VMFolder? {
            Self.element(named: text, in: folders, name: \.name)
        }

        /// The tag `text` names — by identifier, or by name ignoring case —
        /// `nil` when the file defines none.
        func tag(named text: String) -> VMTag? {
            Self.element(named: text, in: tags, name: \.name)
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

        /// Lists `group` after every other section.
        mutating func append(_ group: VMSmartGroup) {
            sections.append(.smartGroup(group))
        }

        /// Lists `folder` after every other section.
        mutating func append(_ folder: VMFolder) {
            sections.append(.folder(folder))
        }

        /// Stops listing the smart group `id` identifies.
        mutating func removeSmartGroup(_ id: UUID) {
            sections.removeAll { $0.smartGroup?.id == id }
        }

        /// Stops listing the folder `id` identifies.
        mutating func removeFolder(_ id: UUID) {
            sections.removeAll { $0.folder?.id == id }
        }

        /// Moves the section `id` identifies to just before the one
        /// `successor` identifies, or after every other when `successor` is
        /// `nil` or not listed.
        mutating func move(_ id: SidebarSectionID, before successor: SidebarSectionID?) {
            guard id != successor, let from = sections.firstIndex(where: { $0.id == id }) else { return }
            let moved = sections.remove(at: from)
            let to = successor.flatMap { next in sections.firstIndex { $0.id == next } } ?? sections.endIndex
            sections.insert(moved, at: to)
        }

        /// Applies `change` to each smart group `included` admits.
        mutating func editSmartGroups(
            where included: (VMSmartGroup) -> Bool, _ change: (inout VMSmartGroup) -> Void
        ) {
            for index in sections.indices {
                guard case .smartGroup(var group) = sections[index], included(group) else { continue }
                change(&group)
                sections[index] = .smartGroup(group)
            }
        }

        /// Applies `change` to each folder `included` admits.
        mutating func editFolders(where included: (VMFolder) -> Bool, _ change: (inout VMFolder) -> Void) {
            for index in sections.indices {
                guard case .folder(var folder) = sections[index], included(folder) else { continue }
                change(&folder)
                sections[index] = .folder(folder)
            }
        }
    }

    /// One sidebar section: a smart group, a folder, or the library.
    enum Section: Equatable, Sendable, Identifiable {
        case smartGroup(VMSmartGroup)
        case folder(VMFolder)
        /// The section listing every library entry.
        case library

        var id: SidebarSectionID {
            switch self {
            case .smartGroup(let group): .smartGroup(group.id)
            case .folder(let folder): .folder(folder.id)
            case .library: .library
            }
        }

        var smartGroup: VMSmartGroup? {
            guard case .smartGroup(let group) = self else { return nil }
            return group
        }

        var folder: VMFolder? {
            guard case .folder(let folder) = self else { return nil }
            return folder
        }
    }

    /// What the organization holds that a name selects.
    enum Element: Equatable, Sendable {
        case smartGroup, folder, tag

        init(_ kind: VMGroupKind) {
            switch kind {
            case .smartGroup: self = .smartGroup
            case .folder: self = .folder
            }
        }

        /// What a sentence calls one.
        var noun: String {
            switch self {
            case .smartGroup: "smart group"
            case .folder: "folder"
            case .tag: "tag"
            }
        }
    }

    /// Why a change to the organization was refused.
    enum ChangeError: LocalizedError, Equatable {
        case nameRequired(Element)
        case nameTaken(String, Element)
        case nameIsIdentifier(String, Element)
        case unreadable
        case unsaved(String)

        var errorDescription: String? {
            switch self {
            case .nameRequired(let kind):
                "A \(kind.noun) needs a name."
            case .nameTaken(let name, let kind):
                "A \(kind.noun) named \u{201C}\(name)\u{201D} already exists. Give this one another name."
            case .nameIsIdentifier(let name, let kind):
                "\u{201C}\(name)\u{201D} can\u{2019}t name a \(kind.noun): an identifier already names one."
            case .unreadable:
                VMOrganizationDirectory.unreadableMessage
            case .unsaved(let reason):
                "Kernova couldn\u{2019}t save its smart groups, folders and tags: \(reason)"
            }
        }
    }

    /// What the file held the last time it was read or written: every section,
    /// the library's included, in the order the sidebar lists them.
    typealias State = ConfigFileState<File>

    private(set) var state: State = .listed(File())

    /// Every section, the library's included, in the order the sidebar lists
    /// them; `nil` while the file can't be read.
    var sections: [Section]? { state.listed?.sections }

    /// Every smart group, in the order the sidebar lists them; `nil` while the
    /// file can't be read.
    var smartGroups: [VMSmartGroup]? { state.listed?.smartGroups }

    /// Every folder, in the order the sidebar lists them; `nil` while the file
    /// can't be read.
    var folders: [VMFolder]? { state.listed?.folders }

    /// Every tag, in the order every list of them shows them; `nil` while the
    /// file can't be read.
    var tags: [VMTag]? { state.listed?.tags }

    /// The file the organization persists in, `nil` to keep it in memory only.
    @ObservationIgnored nonisolated let file: CoordinatedJSONFile<File>?

    /// The organization `fileURL` holds — none when there is no file yet.
    init(fileURL: URL?) {
        self.file = fileURL.map(Self.file(at:))
        reload()
    }

    /// The organization file at `url`, as the library's own reads and writes
    /// take it.
    nonisolated static func file(at url: URL) -> CoordinatedJSONFile<File> {
        CoordinatedJSONFile(location: .organization(url), owner: .organization, empty: File())
    }

    /// Reads the file again, taking in what another copy of Kernova sharing
    /// the library wrote since.
    func reload() {
        guard let file else { return }
        let read = file.state(listing: { $0 })
        if read != state { state = read }
        if let unreadable = read.unreadable {
            #log(
                Self.logger, .error,
                "Couldn't read the library organization at \(file.url.path(percentEncoded: false), privacy: .public): \(String(describing: unreadable.problems), privacy: .public)"
            )
        }
    }

    // MARK: - Reads

    /// The smart group `id` identifies, `nil` when the library lists none.
    func smartGroup(withID id: UUID) -> VMSmartGroup? {
        smartGroups?.first { $0.id == id }
    }

    /// The folder `id` identifies, `nil` when the library lists none.
    func folder(withID id: UUID) -> VMFolder? {
        folders?.first { $0.id == id }
    }

    /// The tag `id` identifies, `nil` when the library defines none.
    func tag(withID id: UUID) -> VMTag? {
        tags?.first { $0.id == id }
    }

    /// `base`, or the first of "`base` 2", "`base` 3", … no `element` is
    /// named — what a new one's name field starts from. `base` itself while
    /// the file cannot be read, where creating one is refused anyway.
    func unusedName(from base: String, for element: Element) -> String {
        guard let listed = state.listed else { return base }
        let names =
            switch element {
            case .smartGroup: listed.smartGroups.map(\.name)
            case .folder: listed.folders.map(\.name)
            case .tag: listed.tags.map(\.name)
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
            file.append(group)
        }
        guard let created else { preconditionFailure("A committed create made no smart group") }
        return created
    }

    /// Renames the smart group `id` identifies.
    func renameSmartGroup(_ id: UUID, to name: String) throws {
        try commit { file in
            let name = try Self.validatedName(
                name, of: .smartGroup, for: id, among: file.smartGroups.map { ($0.id, $0.name) })
            file.editSmartGroups(where: { $0.id == id }) { $0.name = name }
        }
    }

    /// Makes the smart group `id` identifies show what `filter` admits.
    func setFilter(_ filter: VMLibraryFilter, ofSmartGroup id: UUID) throws {
        try commit { file in file.editSmartGroups(where: { $0.id == id }) { $0.filter = filter } }
    }

    /// Stops listing the smart group `id` identifies.
    func removeSmartGroup(_ id: UUID) throws {
        try commit { file in file.removeSmartGroup(id) }
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
            file.append(folder)
        }
        guard let created else { preconditionFailure("A committed create made no folder") }
        return created
    }

    /// Renames the folder `id` identifies.
    func renameFolder(_ id: UUID, to name: String) throws {
        try commit { file in
            let name = try Self.validatedName(name, of: .folder, for: id, among: file.folders.map { ($0.id, $0.name) })
            file.editFolders(where: { $0.id == id }) { $0.name = name }
        }
    }

    /// Stops listing the folder `id` identifies; its VMs stay in the library.
    func removeFolder(_ id: UUID) throws {
        try commit { file in file.removeFolder(id) }
    }

    /// Puts each of `entries` the folder `id` identifies does not hold yet
    /// after its members, in `entries`' order.
    func add(_ entries: [UUID], toFolder id: UUID) throws {
        try commit { file in
            file.editFolders(where: { $0.id == id }) { $0.members = Self.unique($0.members + entries) }
        }
    }

    /// Takes the entry `entry` out of the folder `id` identifies.
    func remove(_ entry: UUID, fromFolder id: UUID) throws {
        try commit { file in file.editFolders(where: { $0.id == id }) { $0.members.removeAll { $0 == entry } } }
    }

    /// Moves the member `entry` of the folder `id` identifies to just before
    /// the member `successor`, or after every other when `successor` is `nil`
    /// or no longer a member.
    func move(_ entry: UUID, before successor: UUID?, inFolder id: UUID) throws {
        try commit { file in
            file.editFolders(where: { $0.id == id }) { Self.move(entry, before: successor, in: &$0.members) }
        }
    }

    /// Takes each of `entries` out of every folder.
    func removeFromEveryFolder(_ entries: Set<UUID>) throws {
        try commit { file in
            file.editFolders(where: { _ in true }) { $0.members.removeAll(where: entries.contains) }
        }
    }

    // MARK: - Tags

    /// Defines a new tag named `name` in `color`, after every other.
    @discardableResult
    func createTag(named name: String, color: VMTagColor) throws -> VMTag {
        var created: VMTag?
        try commit { file in
            let tag = VMTag(
                id: UUID(),
                name: try Self.validatedName(name, of: .tag, for: nil, among: file.tags.map { ($0.id, $0.name) }),
                color: color)
            created = tag
            file.tags.append(tag)
        }
        guard let created else { preconditionFailure("A committed create made no tag") }
        return created
    }

    /// Renames the tag `id` identifies.
    func renameTag(_ id: UUID, to name: String) throws {
        try commit { file in
            let name = try Self.validatedName(name, of: .tag, for: id, among: file.tags.map { ($0.id, $0.name) })
            Self.edit(id, in: &file.tags) { $0.name = name }
        }
    }

    /// Shows the tag `id` identifies in `color`.
    func setColor(_ color: VMTagColor, ofTag id: UUID) throws {
        try commit { file in Self.edit(id, in: &file.tags) { $0.color = color } }
    }

    /// Stops defining the tag `id` identifies.
    ///
    /// A smart group filtering on it keeps the condition, which no VM passes
    /// any more: dropping it would widen the group to VMs it never listed.
    func removeTag(_ id: UUID) throws {
        try commit { file in file.tags.removeAll { $0.id == id } }
    }

    // MARK: - Order

    /// Moves the section `id` identifies — a smart group, a folder or the
    /// library — to just before the one `successor` identifies, or after every
    /// other when `successor` is `nil` or no longer listed.
    func moveSection(_ id: SidebarSectionID, before successor: SidebarSectionID?) throws {
        try commit { file in file.move(id, before: successor) }
    }

    // MARK: - Commit

    /// `name` trimmed, refusing an empty one, one spelling an identifier, and
    /// one an element of `named` other than `id` holds, ignoring case — what
    /// lets a name select one.
    private static func validatedName(
        _ name: String, of kind: Element, for id: UUID?, among named: [(id: UUID, name: String)]
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
    private static func edit<Listed: Identifiable>(
        _ id: Listed.ID, in list: inout [Listed], _ change: (inout Listed) -> Void
    ) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
    }

    /// Moves `entry` to just before `successor`, or to the end when
    /// `successor` is `nil` or not in `list`.
    private static func move(_ entry: UUID, before successor: UUID?, in list: inout [UUID]) {
        guard entry != successor, let from = list.firstIndex(of: entry) else { return }
        list.remove(at: from)
        list.insert(entry, at: successor.flatMap { list.firstIndex(of: $0) } ?? list.endIndex)
    }

    /// `ids` with every repeat after the first dropped.
    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Applies `change` to what the file holds now and writes the result
    /// (``CoordinatedJSONFile/update(_:)``), then lists the result.
    private func commit(_ change: (inout File) throws -> Void) throws {
        func changed(_ base: File) throws -> File {
            var next = base
            try change(&next)
            return next
        }
        guard let file else {
            guard let listed = state.listed else { throw ChangeError.unreadable }
            state = .listed(try changed(listed))
            return
        }
        do {
            let written = State.listed(try file.update(changed))
            if written != state { state = written }
        } catch let failure as CoordinatedJSONFile<File>.Failure {
            switch failure {
            case .unreadable(let unreadable):
                state = .unreadable(unreadable)
                throw ChangeError.unreadable
            case .unsaved: throw ChangeError.unsaved(failure.reason)
            }
        }
    }
}

extension VMGroupKind {
    /// What a sentence calls a group of this kind.
    var noun: String { VMOrganizationDirectory.Element(self).noun }
}
