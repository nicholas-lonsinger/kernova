import AppIntents
import Foundation
import KernovaCommandModel

/// How Shortcuts names one remembered USB accessory: the VM that takes it
/// back, and the durable key it is remembered by, persisted as
/// ``VMListedItemIdentifier`` writes it.
struct RememberedUSBAccessoryEntityID: Hashable, Sendable, EntityIdentifierConvertible {
    /// The VM that takes the accessory back.
    let vm: UUID
    /// ``USBPairingSummary/key``.
    let key: String

    var entityIdentifierString: String {
        VMListedItemIdentifier.string(vm: vm, item: key)
    }

    static func entityIdentifier(for entityIdentifierString: String) -> RememberedUSBAccessoryEntityID? {
        VMListedItemIdentifier.parts(of: entityIdentifierString).map {
            RememberedUSBAccessoryEntityID(vm: $0.vm, key: $0.item)
        }
    }
}

/// One USB accessory a VM takes back automatically, as Shortcuts names it —
/// whether or not it is plugged in.
struct RememberedUSBAccessoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Remembered USB Accessory")

    static let defaultQuery = RememberedUSBAccessoryEntityQuery()

    let id: RememberedUSBAccessoryEntityID

    @Property(title: "Name")
    var name: String

    @Property(title: "Date Remembered")
    var rememberedAt: Date

    /// The entity `summary` describes on the VM `vm`, accounting for each
    /// ``USBPairingSummary/Field``.
    init(_ summary: USBPairingSummary, vm: UUID) {
        self.id = RememberedUSBAccessoryEntityID(vm: vm, key: summary.key)
        for field in USBPairingSummary.Field.allCases {
            switch field {
            case .name: name = summary.name
            case .pairedAt: rememberedAt = summary.pairedAt
            // In the identifier.
            case .key: break
            // The VM the read named, whose identifier is in this entity's.
            case .vm: break
            }
        }
    }

    /// The name over when it was remembered, as the Sharing settings list it.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(rememberedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// How Shortcuts finds the remembered accessory an intent acts on, scoped to
/// the VM that intent already resolved — not enumerable, for the reason
/// ``SnapshotEntityQuery`` states. ``FindRememberedUSBAccessoriesIntent`` is
/// the action that lists them.
struct RememberedUSBAccessoryEntityQuery: EntityQuery {
    @Dependency private var gateway: VMIntentGateway

    @IntentParameterDependency<ForgetUSBAccessoryIntent>(\.$vm)
    private var forget

    func suggestedEntities() async throws -> [RememberedUSBAccessoryEntity] {
        guard let vm = forget?.vm else { return [] }
        return try await gateway.rememberedUSBAccessories(ofVM: vm.id)
    }

    func entities(
        for identifiers: [RememberedUSBAccessoryEntityID]
    ) async throws -> [RememberedUSBAccessoryEntity] {
        await VMListedItemIdentifier.entities(identifiers, vm: \.vm) {
            try await gateway.rememberedUSBAccessories(ofVM: $0)
        }
    }
}
