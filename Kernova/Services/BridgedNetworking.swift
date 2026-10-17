import Foundation
import KernovaLogging
import SystemConfiguration
import Virtualization

/// Answers from the live host: `VZBridgedNetworkInterface` for the bridgeable
/// list, the SystemConfiguration dynamic store for the default route.
struct HostBridgedInterfaceProvider: BridgedInterfaceProviding {
    private static let logger = KernovaLogger(
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
            #log(Self.logger, .fault, "SCDynamicStoreCreate returned nil — reporting no primary interface")
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
