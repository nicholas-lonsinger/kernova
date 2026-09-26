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

/// Why an accessory arrived, which decides whether anything may act on it.
enum USBAccessoryArrival: Sendable, Equatable {
    /// Nobody was waiting for this unit: a device the user just plugged in and
    /// assigned, or one coming back from a reset nothing asked for.
    case fresh
    /// A caller was already waiting for exactly this unit and has just been
    /// answered — the put-back a warm capture owes. That caller owns the
    /// accessory, so nothing else may route it.
    case awaitedReturn
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

    /// Called when a newly assigned accessory arrives, with why it did.
    var onAccessoryAssigned: (@MainActor (USBAccessoryInfo, USBAccessoryArrival) -> Void)? {
        get set
    }

    /// What the guests are holding, asked whenever a new assignment's identity
    /// is composed.
    ///
    /// macOS withdraws an accessory a guest has captured, so `accessories`
    /// alone says a key is free while a guest's record still answers to it —
    /// and a second unit reporting the same serial would take that key and be
    /// read as the first one coming back from a detach.
    ///
    /// `nil` is "no guest holds anything", which is what a harness with no
    /// roster means.
    var accessoriesHeldByGuests: (@MainActor () -> [USBAccessoryInfo])? { get set }

    /// Registers the listener that populates `accessories`. Idempotent; the
    /// registration lives for the process.
    func startObserving()

    /// The accessory now carrying `identity`, waiting up to `timeout` for
    /// macOS to assign one that does.
    ///
    /// Detaching a passthrough device destroys the capture behind it, which
    /// resets the device and re-registers drivers for it, so the same stick
    /// comes back as a different IORegistry node after a delay nothing bounds
    /// — under a second with the host idle, and far longer when it has a
    /// volume to unmount first. Event-driven for that reason: the wait ends on
    /// the assignment, and `timeout` is only the backstop.
    ///
    /// `identity` carries the receptacle the unit was in, so an accessory
    /// reporting the same serial from somewhere else answers nothing here.
    /// Cancelling the calling task ends the wait with `nil` immediately.
    func accessory(matching identity: USBAccessoryIdentity, appearingWithin timeout: Duration)
        async -> USBAccessoryInfo?

    /// Attaches the accessory `reservation` names to the live USB controller
    /// of the VM it is reserved for.
    func attach(_ reservation: borrowing VMAccessoryReservation) async throws -> AttachedUSBAccessory

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
    static func makeService(entitlements: EntitlementService)
        -> (any USBAccessoryProviding)?
    {
        guard entitlements.supportsUSBAccessories else { return nil }
        // `supportsUSBAccessories` already answers the OS question; the
        // compiler needs it spelled here to allow the initializer.
        guard #available(macOS 27.0, *) else { return nil }
        return USBAccessoryService()
    }
}
