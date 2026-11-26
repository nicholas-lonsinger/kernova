import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaLogging

/// The names the library gives its VMs and arrivals: each one's own in the
/// library (``NameRule``), whatever the bundles on disk store.
///
/// What a bundle stores is only a claim. Bundles share no lock, several copies
/// of Kernova load one library, and a bundle can be dragged into the VMs
/// folder holding any name, so two can store one name. A VM's name is instead
/// worked out from every entry the library lists, the same way in every copy,
/// and nothing else is ever a VM's name (``VMInstance/configuration``).
extension VMLibrary {
    /// What a new VM is called until it is given a name, and what one whose
    /// stored name is empty is given.
    package nonisolated static let defaultVMName = "My Virtual Machine"

    /// Gives every VM and arrival the name ``assignedNames(_:)`` works out for
    /// the entries listed now — run whenever the entries change, once for a
    /// batch (``changeEntries(_:)``), and whenever a bundle's stored name,
    /// creation date or date added moves
    /// (``VMLibraryConfigurationPolicy/namingInputsMoved()``).
    func reassignNames() {
        let named = entries.compactMap(\.addressable)
        let assigned = Self.assignedNames(named.map(\.nameClaim))
        for entry in named {
            guard let name = assigned[entry.id] else { continue }
            switch entry {
            case .vm(let instance): instance.assignName(name)
            case .arriving(let arrival): arrival.assignName(name)
            }
        }
    }

    /// The name each claim goes by: walked in ``VMNameOrder``, the same in
    /// every copy of Kernova whatever order the entries were read in, each
    /// takes the name ``NameRule/assignment(of:shape:fallback:)`` gives
    /// it — so the newer of two entries storing one name is the one that gives
    /// it up.
    nonisolated static func assignedNames(_ claims: [VMNameClaim]) -> [UUID: String] {
        let ordered = claims.sorted { $0.order < $1.order }
        let names = NameRule.assignment(of: ordered.map(\.storedName)) { _ in defaultVMName }
        return Dictionary(zip(ordered.map(\.order.id), names), uniquingKeysWith: { first, _ in first })
    }

    /// Writes each VM's name over the one its bundle stores, where the two
    /// differ and this copy may write the bundle — through the edit a rename
    /// takes, and only while the file still stores the name the assignment
    /// read, so a rename another copy made since stands.
    ///
    /// A VM this copy may not write keeps its name in memory, with a notice in
    /// the log and nothing on screen; the next pass that runs for another
    /// reason tries again.
    func persistAssignedNames() {
        for instance in instances {
            let stored = instance.bundle.configuration.name
            let assigned = instance.name
            guard assigned != stored else { continue }
            do {
                try instance.activity.edit(.rename) { permit in
                    try permit.bundle.commitConfiguration { config in
                        guard config.name == stored else { return }
                        config.name = assigned
                    }
                }
            } catch {
                let reason = (error as? VMAdmissionRefusal)?.refusal.logDescription ?? error.localizedDescription
                logger.log(
                    .notice,
                    "Left '\(stored, privacy: .public)' stored for the VM named '\(assigned, privacy: .public)': \(reason, privacy: .public)"
                )
                continue
            }
            guard instance.bundle.configuration.name != stored else { continue }
            logger.log(
                .notice,
                "Stored '\(instance.bundle.configuration.name, privacy: .public)' for the VM that stored '\(stored, privacy: .public)', a name another VM in the library goes by"
            )
        }
    }

    // MARK: - Names a caller chooses

    /// `proposed` as the name of the VM `id` identifies — or of a new one,
    /// for `nil` — beside every other VM and arrival
    /// (``NameRule/validated(_:among:shape:)``).
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` with the refusal's own
    ///   words.
    func validatedName(_ proposed: String, for id: UUID?) throws -> String {
        do throws(NameRule.Refusal) {
            return try NameRule.validated(proposed, among: names(excluding: id))
        } catch {
            throw CommandError.invalidArgument(error.sentence(about: "virtual machine"))
        }
    }

    /// The name a new entry asking for `proposed` goes by: `proposed` where
    /// it is free, else the first free name from it
    /// (``NameRule/name(for:fallback:among:shape:)``).
    func freeName(from proposed: String) -> String {
        NameRule.name(for: proposed, fallback: Self.defaultVMName, among: names(excluding: nil))
    }

    /// The names every VM and arrival but `id`'s goes by.
    func names(excluding id: UUID?) -> [String] {
        entries.compactMap(\.addressable).filter { $0.id != id }.map(\.name)
    }
}

/// What one entry stores as its name, and where it stands in the walk that
/// gives names out.
struct VMNameClaim: Sendable, Equatable {
    let storedName: String
    let order: VMNameOrder
}

/// Where an entry stands among those claiming a name: older first, by facts
/// every copy of Kernova reads alike — when its bundle was put in the VMs
/// folder where the volume keeps that, then when it was created, then its
/// identifier — and an arrival, which only this copy lists, after every
/// published bundle.
struct VMNameOrder: Comparable, Sendable {
    enum Standing: Int, Sendable {
        case publishedOnRecord
        case published
        case arriving
    }

    let standing: Standing
    let dateAdded: Date?
    let createdAt: Date
    let id: UUID
    /// `id` spelled out once, for the comparisons a sort makes.
    private let idText: String

    private init(standing: Standing, dateAdded: Date?, createdAt: Date, id: UUID) {
        self.standing = standing
        self.dateAdded = dateAdded
        self.createdAt = createdAt
        self.id = id
        idText = id.uuidString
    }

    /// A published bundle's place: `dateAdded` is when it joined the VMs
    /// folder, `nil` where the volume keeps no such date.
    static func published(dateAdded: Date?, createdAt: Date, id: UUID) -> Self {
        Self(
            standing: dateAdded == nil ? .published : .publishedOnRecord, dateAdded: dateAdded,
            createdAt: createdAt, id: id)
    }

    /// An arrival's place.
    static func arriving(createdAt: Date, id: UUID) -> Self {
        Self(standing: .arriving, dateAdded: nil, createdAt: createdAt, id: id)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.standing.rawValue, lhs.dateAdded ?? .distantPast, lhs.createdAt, lhs.idText)
            < (rhs.standing.rawValue, rhs.dateAdded ?? .distantPast, rhs.createdAt, rhs.idText)
    }
}

extension AddressableEntry {
    /// What this entry stores as its name, and its place in the walk.
    @MainActor var nameClaim: VMNameClaim {
        switch self {
        case .vm(let instance):
            let bundle = instance.bundle
            let stored = bundle.configuration
            return VMNameClaim(
                storedName: stored.name,
                order: .published(dateAdded: bundle.dateAdded, createdAt: stored.createdAt, id: instance.id))
        case .arriving(let arrival):
            return VMNameClaim(
                storedName: arrival.requested.name,
                order: .arriving(createdAt: arrival.requested.createdAt, id: arrival.id))
        }
    }
}
