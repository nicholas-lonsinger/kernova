import AppIntents
import Foundation
import KernovaKit

/// How Shortcuts names one snapshot: the VM that owns it, and the snapshot.
///
/// Snapshot identifiers are unique only within a bundle's manifest, and the
/// composite is what makes a saved Shortcut re-resolvable. Shortcuts persists a
/// chosen entity's identifier and hands it back to ``SnapshotEntityQuery``'s
/// `entities(for:)` later, which can run with no intent parameter bound — so
/// the identifier has to carry the VM to read the manifest from.
struct SnapshotEntityID: Hashable, Sendable, EntityIdentifierConvertible {
    /// The VM whose manifest lists the snapshot.
    let vm: UUID
    /// The snapshot's own identifier.
    let snapshot: UUID

    var entityIdentifierString: String { "\(vm.uuidString)/\(snapshot.uuidString)" }

    static func entityIdentifier(for entityIdentifierString: String) -> SnapshotEntityID? {
        let halves = entityIdentifierString.split(
            separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2,
            let vm = UUID(uuidString: String(halves[0])),
            let snapshot = UUID(uuidString: String(halves[1]))
        else { return nil }
        return SnapshotEntityID(vm: vm, snapshot: snapshot)
    }
}

/// One of a VM's named restore points, as Shortcuts names it.
///
/// Built from a ``SnapshotSummary`` and the owning VM's identifier, so what
/// this surface shows can never drift from what the command core reads.
struct SnapshotEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Snapshot")

    static let defaultQuery = SnapshotEntityQuery()

    let id: SnapshotEntityID

    @Property(title: "Name")
    var name: String

    @Property(title: "Notes")
    var notes: String

    /// What the capture holds, as its stable wire name — `warm` for one that
    /// carries the guest's memory, `cold` for the disks alone.
    @Property(title: "Kind")
    var kind: String

    @Property(title: "Captured")
    var createdAt: Date

    @Property(title: "Is Current")
    var isCurrent: Bool

    @Property(title: "Is Ephemeral Baseline")
    var isEphemeralBaseline: Bool

    init(_ summary: SnapshotSummary, vm: UUID) {
        self.id = SnapshotEntityID(vm: vm, snapshot: summary.id)
        self.name = summary.name
        self.notes = summary.notes
        self.kind = summary.kind
        self.createdAt = summary.createdAt
        self.isCurrent = summary.isCurrent
        self.isEphemeralBaseline = summary.isEphemeralBaseline
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(Self.captureDescription(kind, createdAt))")
    }

    /// What a capture reads back as in the snapshot list's own words — the date
    /// it was taken, and for a cold one that it holds no memory image.
    static func captureDescription(_ kind: String, _ createdAt: Date) -> String {
        let taken = SnapshotDateFormat.string(from: createdAt)
        guard VMSnapshotKind(rawValue: kind) == .cold else { return taken }
        return "\(taken) \u{00B7} Disks only"
    }
}

/// How Shortcuts finds the snapshot an intent acts on, scoped to the VM that
/// intent already resolved.
///
/// Unscoped, a picker meaning one VM would offer every snapshot in the library.
/// Each snapshot-addressing intent declares its VM parameter here, and
/// ``suggestedEntities()`` reads whichever is bound.
///
/// Scoping is why this offers suggestions rather than being enumerable: an
/// enumerable query is also published as a Find action of its own, and a
/// standalone action carries none of these projections — so it could only ever
/// answer an empty list. ``FindSnapshotsIntent`` is the action that lists
/// snapshots, and it takes the VM as a parameter.
struct SnapshotEntityQuery: EntityQuery {
    @Dependency private var gateway: VMIntentGateway

    @IntentParameterDependency<RevertToSnapshotIntent>(\.$vm)
    private var revert

    @IntentParameterDependency<DeleteSnapshotIntent>(\.$vm)
    private var delete

    @IntentParameterDependency<RenameSnapshotIntent>(\.$vm)
    private var rename

    @IntentParameterDependency<SetSnapshotNotesIntent>(\.$vm)
    private var setNotes

    /// The VM the intent being edited has resolved, `nil` when none is.
    private var scope: VMEntity? {
        revert?.vm ?? delete?.vm ?? rename?.vm ?? setNotes?.vm
    }

    func suggestedEntities() async throws -> [SnapshotEntity] {
        guard let scope else { return [] }
        return try await gateway.snapshots(ofVM: scope.id)
    }

    /// Re-resolves saved identifiers, which needs no parameter bound: each one
    /// carries the VM whose manifest lists it.
    ///
    /// A VM that has since left the library drops its identifiers rather than
    /// failing the whole resolution — the same way a saved VM reference does.
    /// The gateway has already logged that refusal.
    func entities(for identifiers: [SnapshotEntityID]) async throws -> [SnapshotEntity] {
        var found: [SnapshotEntityID: SnapshotEntity] = [:]
        for vm in Set(identifiers.map(\.vm)) {
            for entity in (try? await gateway.snapshots(ofVM: vm)) ?? [] {
                found[entity.id] = entity
            }
        }
        return identifiers.compactMap { found[$0] }
    }
}
