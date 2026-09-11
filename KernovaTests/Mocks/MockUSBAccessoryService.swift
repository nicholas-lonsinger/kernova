import Foundation

@testable import Kernova

/// Stand-in for `USBAccessoryProviding` over an explicit accessory list, with
/// no accessory listener and no USB controller behind it.
@MainActor
final class MockUSBAccessoryService: USBAccessoryProviding {
    var accessories: [USBAccessoryInfo] = []
    var onAccessoryAssigned: (@MainActor (USBAccessoryInfo) -> Void)?
    var onAccessoryWithdrawn: (@MainActor (UInt64) -> Void)?

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

    // MARK: - Suspension

    /// Suspends the next `attach` until ``resumeAttach()``, so a test can hold
    /// an edit open and observe what happens underneath it. One at a time, for
    /// the reason `SuspendingMockRemovableMediaDeviceService` states.
    var suspendNextAttach = false

    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var suspendedNotification: CheckedContinuation<Void, Never>?

    /// Waits until a suspended `attach` has actually reached its suspension.
    func attachStarted() async {
        if suspendedContinuation != nil { return }
        await withCheckedContinuation { continuation in
            suspendedNotification = continuation
        }
    }

    /// Lets the suspended `attach` finish.
    func resumeAttach() {
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }

    private func suspendIfNeeded() async {
        guard suspendNextAttach else { return }
        suspendNextAttach = false
        precondition(suspendedContinuation == nil, "Only one attach can be suspended at a time")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            suspendedContinuation = continuation
            suspendedNotification?.resume()
            suspendedNotification = nil
        }
    }

    func attach(_ registryID: UInt64, to instance: VMInstance) async throws -> AttachedUSBAccessory {
        attachedRegistryIDs.append(registryID)
        await suspendIfNeeded()
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
