import Foundation
import KernovaKit

/// The USB accessory verbs: what a guest is holding, what macOS has assigned to
/// Kernova that nothing holds, and the two edits that move one between them.
///
/// Every one of them refuses on the capability first, so a build that cannot
/// pass accessories through answers the same way whichever verb asks.
extension VMCommandCore {
    /// What a refusal calls the capability, completing "This virtual machine
    /// does not support …".
    private static let usbAccessoryCapability = "USB accessory passthrough"

    // MARK: - Reads

    func usbAccessories(of selector: VMSelector) throws -> [USBAccessorySummary] {
        try requireUSBAccessoryService()
        return try resolve(selector).liveUSBAccessories.map {
            summary(of: $0.accessory, deviceID: $0.deviceID)
        }
    }

    func availableUSBAccessories() throws -> [USBAccessorySummary] {
        // Host-scoped: this names no VM, so a refusal must not describe one.
        guard let service = lifecycle.usbAccessoryService else {
            throw CommandError.unsupportedByBuild(capability: Self.usbAccessoryCapability)
        }
        let held = heldAccessoryIDs()
        return service.accessories
            .filter { !held.contains($0.registryID) }
            .map { summary(of: $0) }
    }

    // MARK: - Edits

    func attachUSBAccessory(_ selector: VMSelector, accessory registryID: UInt64) async throws {
        let (instance, sessionID) = try admitUSBAccessoryEdit(selector)
        // A guest captures an accessory exclusively, so a second attach could
        // only fail inside VZ. Refusing here is what makes the listings' filter
        // a presentation detail rather than the only thing standing between two
        // guests and the same device.
        guard !heldAccessoryIDs().contains(registryID) else {
            throw CommandError.operationFailed(
                verb: .editUSBAccessory,
                message: "That USB accessory is already attached to a virtual machine.")
        }
        do {
            let attached = try await lifecycle.attachUSBAccessory(
                registryID, to: instance, for: sessionID)
            Self.logger.notice(
                "Attached USB accessory \(attached.accessory.displayName, privacy: .public) to '\(instance.name, privacy: .public)'"
            )
        } catch {
            throw usbRefusal(error, on: instance)
        }
    }

    func detachUSBAccessory(_ selector: VMSelector, device deviceID: UUID) async throws {
        let (instance, sessionID) = try admitUSBAccessoryEdit(selector)
        do {
            try await lifecycle.detachUSBAccessory(
                deviceID: deviceID, from: instance, for: sessionID)
            Self.logger.notice(
                "Detached USB accessory \(deviceID, privacy: .public) from '\(instance.name, privacy: .public)'"
            )
        } catch {
            throw usbRefusal(error, on: instance)
        }
    }

    /// The VM an accessory edit acts on and the session it acts for, or the
    /// refusal the build, the selector or the VM's state owes first.
    ///
    /// The session is read here and carried into the lifecycle call, so an edit
    /// overtaken by a stop refuses rather than driving the controller of
    /// whichever session came next.
    private func admitUSBAccessoryEdit(_ selector: VMSelector) throws -> (VMInstance, UUID) {
        try requireUSBAccessoryService()
        let instance = try resolve(selector)
        try require(.editUSBAccessories, on: instance)
        guard let sessionID = instance.attachableSessionID else { throw invalidState(instance) }
        return (instance, sessionID)
    }

    // MARK: - Support

    /// The service that moves accessories on and off a guest, or the refusal a
    /// build without the capability owes.
    @discardableResult
    private func requireUSBAccessoryService() throws -> any USBAccessoryProviding {
        guard let service = lifecycle.usbAccessoryService else {
            throw CommandError.unsupported(capability: Self.usbAccessoryCapability)
        }
        return service
    }

    /// Every accessory identifier some guest in the library is holding.
    ///
    /// The one derivation both listings and the attach gate read, so what
    /// `availableUSBAccessories()` offers and what an attach accepts cannot
    /// drift apart.
    private func heldAccessoryIDs() -> Set<UInt64> {
        Set(library.instances.flatMap { $0.liveUSBAccessories.map(\.accessory.registryID) })
    }

    /// One accessory as a caller names it, carrying the attachment identifier a
    /// detach takes back when a guest is holding it.
    private func summary(of accessory: USBAccessoryInfo, deviceID: UUID? = nil)
        -> USBAccessorySummary
    {
        USBAccessorySummary(
            registryID: accessory.registryID,
            name: accessory.displayName,
            vendorID: accessory.descriptor.vendorID,
            productID: accessory.descriptor.productID,
            deviceID: deviceID)
    }

    /// The command refusal an attach or detach failure stands for.
    ///
    /// A guest that went away under the call is a state refusal rather than a
    /// failure: what the VM accepts now is what the caller needs to hear.
    private func usbRefusal(_ error: any Error, on instance: VMInstance) -> CommandError {
        guard let accessoryError = error as? USBAccessoryError else {
            return failure(error, verb: .editUSBAccessory, on: instance)
        }
        return switch accessoryError {
        case .noVirtualMachine:
            invalidState(instance)
        case .noUSBController:
            .unsupported(capability: Self.usbAccessoryCapability)
        case .accessoryNotFound, .deviceNotFound:
            .operationFailed(
                verb: .editUSBAccessory, message: accessoryError.localizedDescription)
        }
    }
}
