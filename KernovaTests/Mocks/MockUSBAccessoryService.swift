import Foundation
import KernovaTestSupport

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

    /// Plays macOS assigning `info` to Kernova, listing it and telling whoever
    /// is watching — the callback the coordinator installs, and any wait.
    func assign(_ info: USBAccessoryInfo) {
        accessories.append(info)
        resolveWaits(with: info)
        onAccessoryAssigned?(info)
    }

    // MARK: - Waiting for a Re-Assignment

    /// Identities `accessory(matching:appearingWithin:)` was asked for, in
    /// order.
    private(set) var awaitedIdentities: [USBAccessoryIdentity] = []
    /// How many of those calls are parked right now, and the gate that fires
    /// when one parks — so a test can drive the arrival from the other side
    /// rather than racing it.
    private(set) var parkedWaitCount = 0
    let waitStarted = AsyncGate()

    /// Whether a wait for an identity nothing answers to returns `nil` at once
    /// instead of parking, for the tests where the backstop is not the subject.
    var answersMissingAccessoryImmediately = false

    private struct Wait {
        let identity: USBAccessoryIdentity
        let continuation: CheckedContinuation<USBAccessoryInfo?, Never>
    }

    private var waits: [UUID: Wait] = [:]

    func accessory(matching identity: USBAccessoryIdentity, appearingWithin timeout: Duration)
        async -> USBAccessoryInfo?
    {
        awaitedIdentities.append(identity)
        if let already = accessories.first(where: { $0.identity == identity }) { return already }
        if answersMissingAccessoryImmediately { return nil }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            waits[token] = Wait(identity: identity, continuation: continuation)
            parkedWaitCount += 1
            waitStarted.notify()
        }
    }

    private func resolveWaits(with info: USBAccessoryInfo) {
        for (token, wait) in waits where wait.identity == info.identity {
            waits.removeValue(forKey: token)
            parkedWaitCount -= 1
            wait.continuation.resume(returning: info)
        }
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
    ///
    /// `serial` present gives it the strong identity form; `nil` leaves it
    /// identified by `receptacle`, and both `nil` leaves it with no durable
    /// identity at all.
    static func accessory(
        registryID: UInt64, vendorID: UInt16 = 0x0403, productID: UInt16 = 0x6001,
        deviceClass: UInt8 = 0xFF, deviceVersion: UInt16 = 0x0100,
        serial: String? = nil, receptacle: String? = nil, vendorName: String? = nil,
        productName: String? = nil
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
            node: node)
    }
}
