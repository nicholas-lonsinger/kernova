import AccessoryAccess
import Foundation
import Virtualization
import os

/// The one type that touches AccessoryAccess, and the one that builds a
/// `VZUSBPassthroughDevice`.
///
/// Registration is process-wide and unfiltered: matching criteria narrow which
/// accessories a listener hears about, and Kernova has no business narrowing
/// what the user may assign to it.
@available(macOS 27.0, *)
@MainActor
final class USBAccessoryService: USBAccessoryProviding {
    private(set) var accessories: [USBAccessoryInfo] = []
    var onAccessoryAssigned: (@MainActor (USBAccessoryInfo, USBAccessoryArrival) -> Void)?
    var accessoriesHeldByGuests: (@MainActor () -> [USBAccessoryInfo])?

    /// The live `AAUSBAccessory` behind each entry in `accessories`. VZ needs
    /// the object itself to capture the device; every other layer names it by
    /// `registryID`.
    private var held: [UInt64: AAUSBAccessory] = [:]

    /// AccessoryAccess holds its listener weakly; the service retains it.
    private var listener: AccessoryListener?

    /// Where the durable half of an accessory's description comes from.
    private let registry: any USBAccessoryRegistryReading

    /// Callers waiting for a particular unit to be assigned again, keyed by a
    /// token so a backstop and an arrival cannot both answer one of them.
    private var pendingMatches: [UUID: PendingMatch] = [:]

    private struct PendingMatch {
        let identity: USBAccessoryIdentity
        let continuation: CheckedContinuation<USBAccessoryInfo?, Never>
    }

    private static let logger = Logger(subsystem: "app.kernova", category: "USBAccessoryService")

    init(registry: any USBAccessoryRegistryReading = USBAccessoryRegistry()) {
        self.registry = registry
    }

    func startObserving() {
        guard listener == nil else { return }

        let shim = AccessoryListener(
            didConnect: { [weak self] accessory in
                Task { @MainActor in self?.absorb(accessory) }
            },
            didDisconnect: { [weak self] accessory in
                let registryID = accessory.registryID
                Task { @MainActor in self?.withdraw(registryID) }
            })
        listener = shim

        AAUSBAccessoryManager.shared.registerListener(shim, matchingCriteria: []) {
            [weak self] existing, error in
            Task { @MainActor in
                guard let self else { return }
                if let error = error as NSError? {
                    Self.logger.error(
                        "USB accessory listener registration failed: \(error.domain, privacy: .public) \(error.code) \(error.localizedFailureReason ?? "", privacy: .public)"
                    )
                    self.listener = nil
                    return
                }
                Self.logger.notice(
                    "USB accessory listener registered with \(existing.count) accessory(ies) already assigned"
                )
                for accessory in existing {
                    self.absorb(accessory)
                }
            }
        }
    }

    /// Records an accessory the user assigned to Kernova and offers it onward.
    private func absorb(_ accessory: AAUSBAccessory) {
        let registryID = accessory.registryID
        guard held[registryID] == nil else { return }
        guard let descriptor = USBDeviceDescriptor.parse(accessory.deviceDescriptorData) else {
            Self.logger.warning(
                "Ignoring USB accessory \(registryID): its device descriptor did not parse")
            return
        }

        let node = registry.properties(ofAccessory: registryID)
        // What a guest is holding counts as claimed even though macOS withdrew
        // it: the guest's record still answers to that key, and a second unit
        // reporting the same serial would otherwise be taken for that one
        // coming back from a detach.
        let info = USBAccessoryInfo.make(
            registryID: registryID,
            descriptor: descriptor,
            configurationDescriptor: accessory.configurationDescriptorData,
            node: node,
            claimedBy: accessories + (accessoriesHeldByGuests?() ?? []))
        logIdentityGaps(registryID, node: node, identity: info.identity)
        held[registryID] = accessory
        accessories.append(info)
        Self.logger.notice(
            "USB accessory assigned to Kernova: \(info.displayName, privacy: .public) (\(registryID), \(Self.identityText(info), privacy: .public))"
        )
        // Answered first, so the arrival says whether somebody was already
        // waiting for this exact unit rather than leaving that to a guess
        // about timing.
        let arrival: USBAccessoryArrival =
            resolvePendingMatches(with: info) ? .awaitedReturn : .fresh
        onAccessoryAssigned?(info, arrival)
    }

    /// Drops an accessory macOS took back.
    ///
    /// Routine rather than exceptional: a guest capturing an accessory is
    /// itself a reason for macOS to withdraw it, and a fast user switch or a
    /// console logout withdraws every one of them.
    private func withdraw(_ registryID: UInt64) {
        guard held.removeValue(forKey: registryID) != nil else { return }
        accessories.removeAll { $0.registryID == registryID }
        Self.logger.notice("USB accessory withdrawn from Kernova: \(registryID)")
    }

    /// Says why an assignment carries no durable key.
    ///
    /// Each shape is a `.warning` with the same consequence: what comes back
    /// after a detach cannot be recognised as this unit, so a warm capture
    /// cannot put it back on the guest and a stale record of it cannot be
    /// reconciled. A node that answers while carrying neither a serial index
    /// nor a receptacle is also the shape a denied property read takes —
    /// `IORegistryEntryCreateCFProperties` reports success with the keys
    /// missing.
    private func logIdentityGaps(
        _ registryID: UInt64, node: USBAccessoryNodeProperties?, identity: USBAccessoryIdentity?
    ) {
        guard let node else {
            Self.logger.warning(
                "No IORegistry node answered for USB accessory \(registryID): it can be attached, but not recognised if it is detached and comes back"
            )
            return
        }
        guard identity == nil else {
            if node.declaresSerialNumber, node.serialNumber == nil {
                Self.logger.warning(
                    "USB accessory \(registryID) declares a serial number its IORegistry node does not carry: identifying it by its port instead"
                )
            }
            return
        }
        if node.receptacleKey == nil {
            Self.logger.warning(
                "USB accessory \(registryID) reported neither a serial number nor a receptacle: it can be attached, but not recognised if it is detached and comes back"
            )
        } else {
            Self.logger.warning(
                "USB accessory \(registryID) answers to a serial and a port another accessory already holds: it can be attached, but not recognised if it is detached and comes back"
            )
        }
    }

    /// How the log names an accessory's durable key.
    private static func identityText(_ info: USBAccessoryInfo) -> String {
        guard let identity = info.identity else { return "no durable identity" }
        return switch identity.form {
        case .serialNumber: "identity \(identity.key)"
        case .receptacle: "identity \(identity.key), by port"
        }
    }

    // MARK: - Waiting for a Re-Assignment

    func accessory(matching identity: USBAccessoryIdentity, appearingWithin timeout: Duration)
        async -> USBAccessoryInfo?
    {
        if let already = accessories.first(where: { $0.identity == identity }) { return already }

        let token = UUID()
        let backstop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resolvePendingMatch(token, with: nil)
        }
        defer { backstop.cancel() }

        // Cancellation ends the wait at once rather than at the backstop: the
        // caller that cancels has stopped having anywhere to put the accessory,
        // and a parked continuation would hold its operation open until the
        // deadline. The in-line check covers a caller already cancelled when it
        // arrived, whose handler has run before the continuation exists.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                pendingMatches[token] = PendingMatch(identity: identity, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolvePendingMatch(token, with: nil) }
        }
    }

    /// Answers every caller waiting for the unit `info` is, reporting whether
    /// any was.
    private func resolvePendingMatches(with info: USBAccessoryInfo) -> Bool {
        guard let identity = info.identity else { return false }
        let tokens = pendingMatches.filter { $0.value.identity == identity }.keys
        for token in tokens {
            resolvePendingMatch(token, with: info)
        }
        return !tokens.isEmpty
    }

    private func resolvePendingMatch(_ token: UUID, with info: USBAccessoryInfo?) {
        guard let pending = pendingMatches.removeValue(forKey: token) else { return }
        pending.continuation.resume(returning: info)
    }

    // MARK: - Attach and Detach

    func attach(_ registryID: UInt64, to instance: VMInstance) async throws -> AttachedUSBAccessory {
        guard let session = instance.session else { throw USBAccessoryError.noVirtualMachine }
        guard session.hasUSBController else { throw USBAccessoryError.noUSBController }
        guard let accessory = held[registryID],
            let info = accessories.first(where: { $0.registryID == registryID })
        else { throw USBAccessoryError.accessoryNotFound }

        let deviceID = try await session.attachUSBDevice {
            let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
            return try VZUSBPassthroughDevice(configuration: configuration)
        }

        Self.logger.notice(
            "Attached USB accessory \(info.displayName, privacy: .public) to '\(instance.name, privacy: .public)' as \(deviceID.uuidString, privacy: .public)"
        )
        return AttachedUSBAccessory(deviceID: deviceID, accessory: info)
    }

    func detach(deviceID: UUID, from instance: VMInstance) async throws {
        guard let session = instance.session else { throw USBAccessoryError.noVirtualMachine }
        guard session.hasUSBController else { throw USBAccessoryError.noUSBController }

        do {
            try await session.detachUSBDevice(uuid: deviceID)
        } catch VMSessionError.usbDeviceNotFound {
            throw USBAccessoryError.deviceNotFound
        } catch VMSessionError.usbControllerUnavailable {
            throw USBAccessoryError.noUSBController
        }

        Self.logger.notice(
            "Detached USB accessory \(deviceID.uuidString, privacy: .public) from '\(instance.name, privacy: .public)'"
        )
    }
}

// MARK: - Listener Shim

/// Bridges `AAUSBAccessoryListener`'s callbacks, which arrive on the accessory
/// manager's own serial queue, onto the main actor.
///
/// `@unchecked Sendable` because `NSObject` is not `Sendable` and the protocol
/// is `NS_SWIFT_SENDABLE`; the only stored state is two `@Sendable` closures.
@available(macOS 27.0, *)
private final class AccessoryListener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    private let didConnect: @Sendable (AAUSBAccessory) -> Void
    private let didDisconnect: @Sendable (AAUSBAccessory) -> Void

    init(
        didConnect: @escaping @Sendable (AAUSBAccessory) -> Void,
        didDisconnect: @escaping @Sendable (AAUSBAccessory) -> Void
    ) {
        self.didConnect = didConnect
        self.didDisconnect = didDisconnect
    }

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        didConnect(usbAccessory)
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        didDisconnect(usbAccessory)
    }
}
