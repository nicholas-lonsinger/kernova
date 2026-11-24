import AppIntents
import Foundation
import KernovaCommandModel

/// How Shortcuts names one USB accessory, from one run of a shortcut to the
/// next.
///
/// An accessory's registry ID changes with every replug and every detach
/// (``USBAccessoryIdentity``), so an accessory is named by the durable key a
/// remembered accessory is stored under. One that has no key is named by its
/// registry ID within this run of Kernova: the ID is valid only while this
/// process holds the accessory, and one from another run can name another
/// accessory.
enum USBAccessoryEntityID: Hashable, Sendable, EntityIdentifierConvertible {
    /// ``USBAccessorySummary/key``.
    case key(String)
    /// ``USBAccessorySummary/registryID``, listed in the run of Kernova `run`
    /// names.
    case registryID(UInt64, run: UUID)

    /// This run of Kernova.
    private static let run = UUID()

    /// What names the accessory `summary` lists.
    init(_ summary: USBAccessorySummary) {
        self = summary.key.map(Self.key) ?? .registryID(summary.registryID, run: Self.run)
    }

    var entityIdentifierString: String {
        switch self {
        case .key(let key): "key/\(key)"
        case .registryID(let registryID, let run): "registry/\(run.uuidString)/\(registryID)"
        }
    }

    static func entityIdentifier(for entityIdentifierString: String) -> USBAccessoryEntityID? {
        let parts = entityIdentifierString.split(
            separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "key":
            return .key(String(parts[1]))
        case "registry":
            let listed = parts[1].split(separator: "/", omittingEmptySubsequences: false)
            guard listed.count == 2, let run = UUID(uuidString: String(listed[0])),
                let registryID = UInt64(listed[1])
            else { return nil }
            return .registryID(registryID, run: run)
        default:
            return nil
        }
    }
}

/// One USB accessory macOS has assigned to Kernova, held by a guest or not, as
/// Shortcuts names it.
struct USBAccessoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "USB Accessory")

    static let defaultQuery = USBAccessoryEntityQuery()

    let id: USBAccessoryEntityID

    @Property(title: "Name")
    var name: String

    /// `idVendor` from the device descriptor.
    @Property(title: "Vendor ID")
    var vendorID: Int

    /// `idProduct` from the device descriptor.
    @Property(title: "Product ID")
    var productID: Int

    /// The entity `summary` describes, accounting for each
    /// ``USBAccessorySummary/Field``.
    init(_ summary: USBAccessorySummary) {
        self.id = USBAccessoryEntityID(summary)
        for field in USBAccessorySummary.Field.allCases {
            switch field {
            case .name: name = summary.name
            case .vendorID: vendorID = Int(summary.vendorID)
            case .productID: productID = Int(summary.productID)
            // The identifier carries the key, or the registry ID of an
            // accessory with none.
            case .key, .registryID: break
            // Names an attachment, which a detach ends; Detach USB Accessory
            // reads it off the guest's own listing as it runs.
            case .deviceID: break
            }
        }
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// How Shortcuts finds the USB accessory an intent acts on: the ones no guest
/// holds for Attach USB Accessory, and the ones the chosen virtual machine's
/// guest holds for Detach USB Accessory — offered once that intent's virtual
/// machine is chosen, and not enumerable, for the reason
/// ``SnapshotEntityQuery`` states. The Find actions list them.
struct USBAccessoryEntityQuery: EntityQuery {
    @Dependency private var gateway: VMIntentGateway

    @IntentParameterDependency<AttachUSBAccessoryIntent>(\.$vm)
    private var attach

    @IntentParameterDependency<DetachUSBAccessoryIntent>(\.$vm)
    private var detach

    func suggestedEntities() async throws -> [USBAccessoryEntity] {
        if let detach { return try await gateway.usbAccessories(attachedTo: detach.vm.id) }
        guard attach != nil else { return [] }
        return try await gateway.availableUSBAccessories()
    }

    /// Re-resolves saved identifiers against every accessory Kernova holds
    /// now; one that is no longer assigned to Kernova — unplugged, say — is
    /// left out.
    func entities(for identifiers: [USBAccessoryEntityID]) async throws -> [USBAccessoryEntity] {
        try await gateway.usbAccessories(withIDs: identifiers)
    }
}
