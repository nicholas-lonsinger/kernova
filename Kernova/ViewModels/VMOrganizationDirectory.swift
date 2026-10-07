import Foundation
import KernovaKit
import KernovaLogging

/// How the library is organized beyond its VMs — its smart groups — and the
/// one writer of the file that holds it.
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
    }

    /// Why a change to the organization was refused.
    enum ChangeError: LocalizedError, Equatable {
        case nameRequired
        case nameTaken(String)
        case unreadable(String)
        case unsaved(String)

        var errorDescription: String? {
            switch self {
            case .nameRequired:
                "A smart group needs a name."
            case .nameTaken(let name):
                "A smart group named \u{201C}\(name)\u{201D} already exists. Give this one another name."
            case .unreadable(let reason):
                "Kernova couldn\u{2019}t read its list of smart groups, so it changes none: \(reason)"
            case .unsaved(let reason):
                "Kernova couldn\u{2019}t save its list of smart groups: \(reason)"
            }
        }
    }

    /// Every smart group, in the order the sidebar lists them.
    private(set) var smartGroups: [VMSmartGroup] = []

    /// Why the file could not be read the last time, `nil` when it was, or
    /// holds nothing yet. A change reads the file again first and refuses
    /// when that read fails, so an unread file is never overwritten.
    private(set) var readFailure: String?

    /// The file the organization persists in, `nil` to keep it in memory only.
    @ObservationIgnored private let file: CoordinatedJSONFile<File>?

    /// The organization `fileURL` holds — none when there is no file yet.
    init(fileURL: URL?) {
        self.file = fileURL.map { CoordinatedJSONFile(url: $0, empty: File(smartGroups: [])) }
        reload()
    }

    /// Reads the file again, taking in what another copy of Kernova sharing
    /// the library wrote since.
    func reload() {
        guard let file else { return }
        do {
            let read = try file.read()
            if read.smartGroups != smartGroups { smartGroups = read.smartGroups }
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

    // MARK: - Reads

    /// The smart group `id` identifies, `nil` when the library lists none.
    func smartGroup(withID id: UUID) -> VMSmartGroup? {
        smartGroups.first { $0.id == id }
    }

    /// `base`, or the first of "`base` 2", "`base` 3", … no smart group is
    /// named — what a new group's name field starts from.
    func unusedName(from base: String) -> String {
        let taken = Set(smartGroups.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Changes

    /// Lists a new smart group named `name` showing what `filter` admits,
    /// after every other.
    @discardableResult
    func createSmartGroup(named name: String, filter: VMLibraryFilter) throws -> VMSmartGroup {
        var created: VMSmartGroup?
        try commit { groups in
            let group = VMSmartGroup(
                id: UUID(), name: try Self.validatedName(name, for: nil, among: groups), filter: filter)
            created = group
            return groups + [group]
        }
        guard let created else { preconditionFailure("A committed create made no smart group") }
        return created
    }

    /// Renames the smart group `id` identifies.
    func renameSmartGroup(_ id: UUID, to name: String) throws {
        try commit { groups in
            let name = try Self.validatedName(name, for: id, among: groups)
            return groups.map { group in
                guard group.id == id else { return group }
                var renamed = group
                renamed.name = name
                return renamed
            }
        }
    }

    /// Makes the smart group `id` identifies show what `filter` admits.
    func setFilter(_ filter: VMLibraryFilter, ofSmartGroup id: UUID) throws {
        try commit { groups in
            groups.map { group in
                guard group.id == id else { return group }
                var edited = group
                edited.filter = filter
                return edited
            }
        }
    }

    /// Drops the named network `id` from every smart group's filter.
    func removeNetwork(_ id: UUID) throws {
        try commit { groups in
            groups.map { group in
                var pruned = group
                pruned.filter = group.filter.removingNetwork(id)
                return pruned
            }
        }
    }

    /// Stops listing the smart group `id` identifies.
    func removeSmartGroup(_ id: UUID) throws {
        try commit { groups in groups.filter { $0.id != id } }
    }

    /// Moves the smart group `id` identifies to just before the one `successor`
    /// identifies, or after every other when `successor` is `nil` or no longer
    /// listed.
    func moveSmartGroup(_ id: UUID, before successor: UUID?) throws {
        guard id != successor else { return }
        try commit { groups in
            guard let moved = groups.first(where: { $0.id == id }) else { return groups }
            var reordered = groups.filter { $0.id != id }
            let index = successor.flatMap { next in reordered.firstIndex { $0.id == next } } ?? reordered.endIndex
            reordered.insert(moved, at: index)
            return reordered
        }
    }

    /// `name` trimmed, refusing an empty one and one another smart group than
    /// `id`'s own is named, ignoring case — what lets a name select a group.
    private static func validatedName(
        _ name: String, for id: UUID?, among groups: [VMSmartGroup]
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChangeError.nameRequired }
        if let other = groups.first(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            throw ChangeError.nameTaken(other.name)
        }
        return trimmed
    }

    /// Applies `change` to the smart groups the file holds now and writes the
    /// result (``CoordinatedJSONFile/update(_:)``), then lists the result.
    private func commit(_ change: ([VMSmartGroup]) throws -> [VMSmartGroup]) throws {
        guard let file else {
            smartGroups = try change(smartGroups)
            return
        }
        do {
            let written = try file.update { File(smartGroups: try change($0.smartGroups)) }
            if written.smartGroups != smartGroups { smartGroups = written.smartGroups }
        } catch let failure as CoordinatedJSONFile<File>.Failure {
            switch failure {
            case .unreadable: throw ChangeError.unreadable(failure.reason)
            case .unsaved: throw ChangeError.unsaved(failure.reason)
            }
        }
        readFailure = nil
    }
}
