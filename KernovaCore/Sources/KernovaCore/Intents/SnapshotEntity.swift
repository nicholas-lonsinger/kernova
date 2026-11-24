import AppIntents
import Foundation
import KernovaCommandModel

/// How Shortcuts names one snapshot: the VM that owns it, and the snapshot,
/// persisted as ``VMListedItemIdentifier`` writes it.
///
/// Snapshot identifiers are unique only within a bundle's manifest.
struct SnapshotEntityID: Hashable, Sendable, EntityIdentifierConvertible {
    /// The VM whose manifest lists the snapshot.
    let vm: UUID
    /// The snapshot's own identifier.
    let snapshot: UUID

    var entityIdentifierString: String {
        VMListedItemIdentifier.string(vm: vm, item: snapshot.uuidString)
    }

    static func entityIdentifier(for entityIdentifierString: String) -> SnapshotEntityID? {
        guard let parts = VMListedItemIdentifier.parts(of: entityIdentifierString),
            let snapshot = UUID(uuidString: parts.item)
        else { return nil }
        return SnapshotEntityID(vm: parts.vm, snapshot: snapshot)
    }
}

/// One of a VM's named restore points, as Shortcuts names it.
///
/// Built from a ``SnapshotSummary`` and the owning VM's identifier.
///
/// The sizes are deferred, read only when asked for: the read walks the
/// snapshot's files, and the query builds an entity for every snapshot a
/// picker offers or a run resolves.
struct SnapshotEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Snapshot")

    static let defaultQuery = SnapshotEntityQuery()

    let id: SnapshotEntityID

    @Property(title: "Name")
    var name: String

    @Property(title: "Notes")
    var notes: String

    /// What the capture holds, as its stable wire name — `warm` for one that
    /// carries the guest's memory, `cold` for one that does not.
    @Property(title: "Kind")
    var kind: String

    @Property(title: "Captured")
    var createdAt: Date

    @Property(title: "Is Current")
    var isCurrent: Bool

    @Property(title: "Is Ephemeral Baseline")
    var isEphemeralBaseline: Bool

    /// ``SnapshotSize/bytes``, `nil` when it can't be read. Narrowed from the
    /// core's `UInt64`, which is not a value Shortcuts carries.
    @DeferredProperty(title: "Size in Bytes")
    var sizeBytes: Int? {
        get async throws { try await sizes.snapshotSize(id).map { Int(clamping: $0.bytes) } }
    }

    /// ``SnapshotSize/privateBytes``, narrowed as ``sizeBytes`` is.
    @DeferredProperty(title: "Private Bytes")
    var privateBytes: Int? {
        get async throws { try await sizes.snapshotSize(id)?.privateBytes.map { Int(clamping: $0) } }
    }

    /// What the sizes are read through.
    private let sizes: VMIntentGateway

    /// The entity `summary` describes, accounting for each
    /// ``SnapshotSummary/Field``.
    init(_ summary: SnapshotSummary, vm: UUID, sizes: VMIntentGateway) {
        self.sizes = sizes
        self.id = SnapshotEntityID(vm: vm, snapshot: summary.id)
        for field in SnapshotSummary.Field.allCases {
            switch field {
            case .id: break  // In the entity's identifier, set above.
            case .name: name = summary.name
            case .notes: notes = summary.notes
            case .kind: kind = summary.kind
            case .createdAt: createdAt = summary.createdAt
            case .isCurrent: isCurrent = summary.isCurrent
            case .isEphemeralBaseline: isEphemeralBaseline = summary.isEphemeralBaseline
            }
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: "\(Self.captureDescription(kind, createdAt))")
    }

    /// What a capture reads back as in the snapshot list's own words — the date
    /// it was taken and the state the snapshot captured.
    static func captureDescription(_ kind: String, _ createdAt: Date) -> String {
        let taken = SnapshotDateFormat.string(from: createdAt)
        guard let kind = VMSnapshotKind(rawValue: kind) else { return taken }
        return "\(taken) \u{00B7} \(SnapshotKindCopy.stateLabel(kind))"
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

    func entities(for identifiers: [SnapshotEntityID]) async throws -> [SnapshotEntity] {
        await VMListedItemIdentifier.entities(identifiers, vm: \.vm) {
            try await gateway.snapshots(ofVM: $0)
        }
    }
}
