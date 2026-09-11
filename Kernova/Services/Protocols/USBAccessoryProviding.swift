import Foundation

/// Failures USB accessory attach and detach report.
enum USBAccessoryError: LocalizedError, Equatable {
    case noVirtualMachine
    case noUSBController
    /// The accessory is no longer assigned to Kernova — unplugged, or handed
    /// to another app — so there is nothing to attach.
    case accessoryNotFound
    /// The VM holds no passthrough device under that identifier.
    case deviceNotFound

    var errorDescription: String? {
        switch self {
        case .noVirtualMachine: "The virtual machine is not running."
        case .noUSBController: "This virtual machine has no USB controller."
        case .accessoryNotFound: "That USB accessory is no longer available."
        case .deviceNotFound: "That USB accessory is not attached to this virtual machine."
        }
    }
}

/// Observes the USB accessories macOS assigns to Kernova, and moves them on and
/// off a running guest's USB controller.
///
/// macOS owns consent: the user assigns a physical accessory to Kernova in
/// Apple's *Virtual Machine Accessories* menu extra, and this type is handed
/// only what they assigned. It never enumerates the host's USB devices, so
/// `accessories` is exactly what Kernova may act on and nothing wider.
@MainActor
protocol USBAccessoryProviding: AnyObject {
    /// The accessories macOS has assigned to Kernova, in arrival order.
    var accessories: [USBAccessoryInfo] { get }

    /// Called when a newly assigned accessory arrives, so a caller can route it
    /// to a guest.
    var onAccessoryAssigned: (@MainActor (USBAccessoryInfo) -> Void)? { get set }

    /// Registers the listener that populates `accessories`. Idempotent; the
    /// registration lives for the process.
    func startObserving()

    /// Attaches the accessory `registryID` names to `instance`'s live USB
    /// controller.
    func attach(_ registryID: UInt64, to instance: VMInstance) async throws -> AttachedUSBAccessory

    /// Detaches the passthrough device `deviceID` names.
    func detach(deviceID: UUID, from instance: VMInstance) async throws
}

/// Where the capability's presence is decided, once.
enum USBAccessorySupport {
    /// The service when this build can pass accessories through, `nil` when it
    /// cannot.
    ///
    /// `nil` collapses both causes of absence — an OS below macOS 27 and a
    /// signature without the entitlement — into the one answer every caller
    /// reads, so no surface has to ask which of them applies.
    @MainActor
    static func makeService(entitlements: EntitlementService = .shared)
        -> (any USBAccessoryProviding)?
    {
        guard entitlements.supportsUSBAccessories else { return nil }
        // `supportsUSBAccessories` already answers the OS question; the
        // compiler needs it spelled here to allow the initializer.
        guard #available(macOS 27.0, *) else { return nil }
        return USBAccessoryService()
    }
}
