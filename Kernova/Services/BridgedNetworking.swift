import Foundation
import SystemConfiguration
import Virtualization

/// A host interface that supports bridged networking, decoupled from VZ for testability.
struct BridgedInterface: Equatable, Sendable {
    let identifier: String
    let localizedDisplayName: String
}

protocol BridgedInterfaceProviding: Sendable {
    /// Host interfaces currently available for bridging.
    @MainActor func interfaces() -> [BridgedInterface]
    /// The identifier of the host's default-route (primary) interface, if known.
    @MainActor func primaryInterfaceIdentifier() -> String?
}

/// Answers from the live host: `VZBridgedNetworkInterface` for the bridgeable
/// list, the SystemConfiguration dynamic store for the default route.
///
/// Both methods are `nonisolated` — a wider isolation than the protocol asks for
/// — so `ConfigurationBuilder`'s nonisolated assembly reads the same host state
/// the settings picker shows, without a second path to it.
struct HostBridgedInterfaceProvider: BridgedInterfaceProviding {
    nonisolated func interfaces() -> [BridgedInterface] {
        VZBridgedNetworkInterface.networkInterfaces.map { interface in
            BridgedInterface(
                identifier: interface.identifier,
                localizedDisplayName: interface.localizedDisplayName ?? interface.identifier)
        }
    }

    nonisolated func primaryInterfaceIdentifier() -> String? {
        // A host with no default route (every interface down, or only interfaces
        // the store hasn't published) has no primary — `nil` is a normal answer.
        guard let store = SCDynamicStoreCreate(nil, "Kernova" as CFString, nil, nil),
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any]
        else { return nil }
        return global[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    }
}

enum BridgedInterfaceSelection {
    /// Chooses the interface to bridge over: the persisted identifier when it is still
    /// available, else the primary interface, else the first available; nil when none exist.
    static func choose(persisted: String?, available: [String], primary: String?) -> String? {
        if let persisted, available.contains(persisted) { return persisted }
        if let primary, available.contains(primary) { return primary }
        return available.first
    }
}
