import AppIntents
import Foundation
import KernovaCommandModel

/// How Shortcuts names one shared directory: the VM that shares it, and the
/// folder's path as that VM carries it, persisted as
/// ``VMListedItemIdentifier`` writes it.
///
/// The path is what a share is addressed by (``SharedDirectorySummary``), and
/// a VM shares a folder at most once.
struct SharedDirectoryEntityID: Hashable, Sendable, EntityIdentifierConvertible {
    /// The VM that shares the folder.
    let vm: UUID
    /// The folder's path.
    let path: String

    var entityIdentifierString: String {
        VMListedItemIdentifier.string(vm: vm, item: path)
    }

    static func entityIdentifier(for entityIdentifierString: String) -> SharedDirectoryEntityID? {
        VMListedItemIdentifier.parts(of: entityIdentifierString).map {
            SharedDirectoryEntityID(vm: $0.vm, path: $0.item)
        }
    }
}

/// One folder a VM shares with its guest, as Shortcuts names it.
struct SharedDirectoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Shared Directory")

    static let defaultQuery = SharedDirectoryEntityQuery()

    let id: SharedDirectoryEntityID

    @Property(title: "Path")
    var path: String

    @Property(title: "Read Only")
    var readOnly: Bool

    /// The entity `summary` describes on the VM `vm`, accounting for each
    /// ``SharedDirectorySummary/Field``.
    init(_ summary: SharedDirectorySummary, vm: UUID) {
        self.id = SharedDirectoryEntityID(vm: vm, path: summary.path)
        for field in SharedDirectorySummary.Field.allCases {
            switch field {
            case .path: path = summary.path
            case .readOnly: readOnly = summary.readOnly
            }
        }
    }

    /// The folder's name over its path, as the Sharing settings list it.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(URL(fileURLWithPath: path).lastPathComponent)", subtitle: "\(path)")
    }
}

/// How Shortcuts finds the shared directory an intent acts on, scoped to the
/// VM that intent already resolved — not enumerable, for the reason
/// ``SnapshotEntityQuery`` states. ``FindSharedDirectoriesIntent`` is the
/// action that lists them.
struct SharedDirectoryEntityQuery: EntityQuery {
    @Dependency private var gateway: VMIntentGateway

    @IntentParameterDependency<RemoveSharedDirectoryIntent>(\.$vm)
    private var remove

    func suggestedEntities() async throws -> [SharedDirectoryEntity] {
        guard let vm = remove?.vm else { return [] }
        return try await gateway.sharedDirectories(ofVM: vm.id)
    }

    func entities(for identifiers: [SharedDirectoryEntityID]) async throws -> [SharedDirectoryEntity] {
        await VMListedItemIdentifier.entities(identifiers, vm: \.vm) {
            try await gateway.sharedDirectories(ofVM: $0)
        }
    }
}
