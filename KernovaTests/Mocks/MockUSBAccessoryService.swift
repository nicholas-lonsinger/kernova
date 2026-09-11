import Foundation

@testable import Kernova

/// Stand-in for `USBAccessoryProviding` over an explicit accessory list, with
/// no accessory listener and no USB controller behind it.
@MainActor
final class MockUSBAccessoryService: USBAccessoryProviding {
    var accessories: [USBAccessoryInfo] = []
    var onAccessoryAssigned: (@MainActor (USBAccessoryInfo) -> Void)?

    var startObservingCallCount = 0
    var attachedRegistryIDs: [UInt64] = []
    var detachedDeviceIDs: [UUID] = []
    var attachError: (any Error)?
    var detachError: (any Error)?

    /// What the next attach answers with, so a test can name the attachment it
    /// will detach. A fresh identifier when nil.
    var nextDeviceID: UUID?

    func startObserving() {
        startObservingCallCount += 1
    }

    func attach(_ registryID: UInt64, to instance: VMInstance) async throws -> AttachedUSBAccessory {
        attachedRegistryIDs.append(registryID)
        if let attachError { throw attachError }
        guard let info = accessories.first(where: { $0.registryID == registryID }) else {
            throw USBAccessoryError.accessoryNotFound
        }
        return AttachedUSBAccessory(deviceID: nextDeviceID ?? UUID(), accessory: info)
    }

    func detach(deviceID: UUID, from instance: VMInstance) async throws {
        detachedDeviceIDs.append(deviceID)
        if let detachError { throw detachError }
    }

    /// One accessory, built from the identifiers every surface names it by.
    static func accessory(
        registryID: UInt64, vendorID: UInt16 = 0x0403, productID: UInt16 = 0x6001,
        deviceClass: UInt8 = 0xFF
    ) -> USBAccessoryInfo {
        USBAccessoryInfo(
            registryID: registryID,
            descriptor: USBDeviceDescriptor(
                usbVersion: 0x0200, deviceClass: deviceClass, deviceSubClass: 0,
                deviceProtocol: 0, vendorID: vendorID, productID: productID,
                deviceVersion: 0x0100))
    }
}
