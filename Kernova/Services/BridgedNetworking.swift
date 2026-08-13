import Foundation
import SystemConfiguration
import Virtualization
import os

/// A host interface that supports bridged networking, decoupled from VZ for testability.
struct BridgedInterface: Equatable, Sendable {
    let identifier: String
    let localizedDisplayName: String
}

protocol BridgedInterfaceProviding: Sendable {
    /// Host interfaces currently available for bridging.
    func interfaces() -> [BridgedInterface]
    /// The identifier of the host's default-route (primary) interface, if known.
    func primaryInterfaceIdentifier() -> String?
}

/// Answers from the live host: `VZBridgedNetworkInterface` for the bridgeable
/// list, the SystemConfiguration dynamic store for the default route.
struct HostBridgedInterfaceProvider: BridgedInterfaceProviding {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "HostBridgedInterfaceProvider")

    func interfaces() -> [BridgedInterface] {
        VZBridgedNetworkInterface.networkInterfaces.map { interface in
            BridgedInterface(
                identifier: interface.identifier,
                localizedDisplayName: interface.localizedDisplayName ?? interface.identifier)
        }
    }

    func primaryInterfaceIdentifier() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Kernova" as CFString, nil, nil) else {
            Self.logger.fault("SCDynamicStoreCreate returned nil — reporting no primary interface")
            assertionFailure("SCDynamicStoreCreate returned nil")
            return nil
        }
        // Either family can carry the default route, so a host routing only over
        // IPv6 still resolves.
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            guard let global = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                let primary = global[kSCDynamicStorePropNetPrimaryInterface as String] as? String
            else { continue }
            return primary
        }
        // A host with no default route (every interface down, or only interfaces
        // the store hasn't published) has no primary — `nil` is a normal answer.
        return nil
    }
}

enum BridgedInterfaceSelection {
    /// Chooses the interface to bridge over: the persisted identifier when it is
    /// still available, else the primary interface; nil when neither resolves.
    static func choose(persisted: String?, available: [String], primary: String?) -> String? {
        if let persisted, available.contains(persisted) { return persisted }
        if let primary, available.contains(primary) { return primary }
        return nil
    }
}
