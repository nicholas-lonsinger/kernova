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
    var onAccessoryAssigned: (@MainActor (USBAccessoryInfo) -> Void)?

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
        if node == nil {
            Self.logger.warning(
                "No IORegistry node answered for USB accessory \(registryID): it can be attached, but not recognised if it is detached and comes back"
            )
        } else if node?.declaresSerialNumber == true, node?.serialNumber == nil {
            Self.logger.warning(
                "USB accessory \(registryID) declares a serial number its IORegistry node does not carry: identifying it by its port instead"
            )
        }

        let info = USBAccessoryInfo.make(
            registryID: registryID,
            descriptor: descriptor,
            configurationDescriptor: accessory.configurationDescriptorData,
            node: node,
            claimedBy: Set(accessories.compactMap { $0.identity?.key }))
        held[registryID] = accessory
        accessories.append(info)
        Self.logger.notice(
            "USB accessory assigned to Kernova: \(info.displayName, privacy: .public) (\(registryID), \(Self.identityText(info), privacy: .public))"
        )
        resolvePendingMatches(with: info)
        onAccessoryAssigned?(info)
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

        return await withCheckedContinuation { continuation in
            pendingMatches[token] = PendingMatch(identity: identity, continuation: continuation)
        }
    }

    /// Answers every caller waiting for the unit `info` is.
    private func resolvePendingMatches(with info: USBAccessoryInfo) {
        guard let identity = info.identity else { return }
        for token in pendingMatches.filter({ $0.value.identity == identity }).keys {
            resolvePendingMatch(token, with: info)
        }
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
