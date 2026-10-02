import Foundation
import KernovaTestSupport

@testable import Kernova

/// Stand-in for `USBAccessoryProviding` over an explicit accessory list, with
/// no accessory listener and no USB controller behind it.
@MainActor
final class MockUSBAccessoryService: USBAccessoryProviding {
    var accessories: [USBAccessoryInfo] = []
    var onAccessoryAssigned: (@MainActor (USBAccessoryInfo) -> Void)?
    var accessoriesHeldByGuests: (@MainActor () -> [USBAccessoryInfo])?

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

    /// Plays macOS assigning `info` to Kernova, listing it and telling the
    /// coordinator.
    func assign(_ info: USBAccessoryInfo) {
        accessories.append(info)
        onAccessoryAssigned?(info)
    }

    /// Assigns a physical unit, composing its identity the way the real service
    /// does: against every key already spoken for, the guests' included.
    @discardableResult
    func assignComposing(
        registryID: UInt64, serial: String? = nil, receptacle: String? = nil,
        vendorID: UInt16 = 0x0403, productID: UInt16 = 0x6001, vendorName: String? = nil,
        productName: String? = nil
    ) -> USBAccessoryInfo {
        let info = Self.accessory(
            registryID: registryID, vendorID: vendorID, productID: productID, serial: serial,
            receptacle: receptacle, vendorName: vendorName, productName: productName,
            claimedBy: accessories + (accessoriesHeldByGuests?() ?? []))
        assign(info)
        return info
    }

    // MARK: - Suspension

    /// Suspends the next `attach` until ``resumeAttach()``, so a test can hold
    /// an edit open and observe what happens underneath it. One at a time, for
    /// the reason `SuspendingMockRemovableMediaDeviceService` states.
    var suspendNextAttach = false

    private var suspendedContinuation: CheckedContinuation<Void, Never>?

    /// Fired as an attach parks in `suspendIfNeeded()`.
    private let suspended = AsyncGate()

    /// Waits until a suspended `attach` has actually reached its suspension,
    /// throwing at the backstop if none does.
    func attachStarted() async throws {
        try await suspended.wait { suspendedContinuation != nil }
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
            suspended.notify()
        }
    }

    func attach(_ reservation: borrowing VMAccessoryReservation) async throws -> AttachedUSBAccessory {
        let registryID = reservation.registryID
        attachedRegistryIDs.append(registryID)
        await suspendIfNeeded()
        if let attachError { throw attachError }
        guard let info = accessories.first(where: { $0.registryID == registryID }) else {
            throw USBAccessoryError.accessoryNotFound
        }
        return AttachedUSBAccessory(deviceID: nextDeviceID ?? UUID(), accessory: info)
    }

    /// Runs inside the next `detach`, before it returns — where macOS can hand
    /// the detached device back while the detach is still in flight.
    var duringNextDetach: (@MainActor () -> Void)?

    func detach(deviceID: UUID, from instance: VMInstance) async throws {
        detachedDeviceIDs.append(deviceID)
        if let duringNextDetach {
            self.duringNextDetach = nil
            duringNextDetach()
        }
        if let detachError { throw detachError }
    }

    /// One accessory, built from the identifiers every surface names it by.
    ///
    /// `serial` present gives it the strong identity form; `nil` leaves it
    /// identified by `receptacle`, and both `nil` leaves it with no durable
    /// identity at all.
    static func accessory(
        registryID: UInt64, vendorID: UInt16 = 0x0403, productID: UInt16 = 0x6001,
        deviceClass: UInt8 = 0xFF, deviceVersion: UInt16 = 0x0100,
        serial: String? = nil, receptacle: String? = nil, vendorName: String? = nil,
        productName: String? = nil, claimedBy held: [USBAccessoryInfo] = []
    ) -> USBAccessoryInfo {
        let descriptor = USBDeviceDescriptor(
            usbVersion: 0x0200, deviceClass: deviceClass, deviceSubClass: 0,
            deviceProtocol: 0, vendorID: vendorID, productID: productID,
            deviceVersion: deviceVersion)
        let node =
            (serial == nil && receptacle == nil && vendorName == nil && productName == nil)
            ? nil
            : USBAccessoryNodeProperties(
                vendorName: vendorName, productName: productName, serialNumber: serial,
                serialNumberIndex: serial == nil ? 0 : 3, ioPortPath: receptacle)
        return USBAccessoryInfo.make(
            registryID: registryID, descriptor: descriptor, configurationDescriptor: nil,
            node: node, claimedBy: held)
    }
}
