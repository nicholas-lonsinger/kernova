import Foundation
import Virtualization

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

    /// Called when a newly assigned accessory arrives.
    var onAccessoryAssigned: (@MainActor (USBAccessoryInfo) -> Void)? { get set }

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

    /// Attaches the accessory `reservation` names to the live USB controller
    /// of the VM it is reserved for.
    func attach(_ reservation: borrowing VMAccessoryReservation) async throws -> AttachedUSBAccessory

    /// Detaches the passthrough device `deviceID` names.
    func detach(deviceID: UUID, from instance: VMInstance) async throws

    /// The device that puts the accessory `reservation` names back on a guest
    /// restored from a saved state holding it under `deviceID`, or `nil` when
    /// the accessory is no longer assigned to Kernova.
    func restoration(
        of reservation: borrowing VMAccessoryReservation, as deviceID: UUID
    ) -> USBPassthroughRestoration?
}

/// A passthrough device a restore configures under the `uuid` its saved state
/// holds it by, and the record the guest holds it under once restored.
///
/// `@unchecked Sendable` for the reason ``ConfigurationBuilder/BuildResult``
/// is: built on the main actor and handed whole to the configuration build,
/// which is the only thing that touches `configuration` afterwards.
struct USBPassthroughRestoration: @unchecked Sendable {
    let registryID: UInt64
    /// `deviceID` is the saved `uuid`.
    let attached: AttachedUSBAccessory
    /// Carries `attached.deviceID` as its `uuid`.
    let configuration: any VZUSBDeviceConfiguration
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
