import Foundation
import KernovaKit
import KernovaLogging

/// The named-network verbs: the library's networks, which a VM joins through
/// its `network.membership` key.
extension VMCommandCore {
    // MARK: - Reads

    func networks() -> [NetworkSummary] {
        library.networks.networks.map(summary)
    }

    /// `network` as every read surface reports it, with the VMs on it.
    func summary(_ network: VMNamedNetwork) -> NetworkSummary {
        NetworkSummary(
            id: network.id, name: network.name, kind: NetworkKind(network.kind),
            members: library.instances.filter {
                library.networks.network(joinedBy: $0.configuration)?.id == network.id
            }.map(summary))
    }

    // MARK: - Edits

    @discardableResult
    func createNetwork(name: String, kind: NetworkKind) throws -> NetworkSummary {
        let kind = VmnetNetworkKind(kind)
        let probe = VMJoinedNetwork.vmnet(VmnetNetworkID(kind: kind, scope: .named(UUID())))
        guard library.entitlements.canAttach(probe) else {
            throw CommandError.unsupportedByBuild(capability: probe.entitledCapability)
        }
        let network = try library.networks.create(name: name, kind: kind, verb: .createNetwork)
        #log(
            Self.logger, .notice,
            "Created the \(kind.rawValue, privacy: .public) network \(network.id.uuidString, privacy: .public)"
        )
        return summary(network)
    }

    func renameNetwork(_ network: String, to newName: String) throws {
        let network = try library.networks.requireNetwork(named: network)
        try library.networks.rename(network.id, to: newName, verb: .renameNetwork)
        #log(Self.logger, .notice, "Renamed the network \(network.id.uuidString, privacy: .public)")
    }

    func deleteNetwork(_ network: String) throws {
        let network = try library.networks.requireNetwork(named: network)
        // Every VM naming it, whatever its mode: one whose membership is inert
        // now — Bridged, or no device — would rejoin the network's identifier
        // at its next mode change.
        let naming = library.instances.filter {
            $0.configuration.networkMembership == .network(network.id)
        }
        let key = VMConfigurationKeyRegistry.networkMembership
        let isolated = VMNetworkMembership.isolated.rawValue
        // Every move is judged before any lands, so a refusal moves nothing.
        for instance in naming {
            try requireGates(for: [(key: key, value: isolated)], on: instance)
            var moved = instance.configuration
            moved.networkMembership = .isolated
            if let joined = moved.joinedNetwork, !library.entitlements.canAttach(joined) {
                throw CommandError.unsupportedByBuild(capability: joined.entitledCapability)
            }
        }
        for instance in naming {
            try setConfiguration(
                .id(instance.instanceID), assignments: [key.assigning(isolated)], consent: .none)
        }
        try library.networks.remove(network.id, verb: .deleteNetwork)
        #log(
            Self.logger, .notice,
            "Deleted the network \(network.id.uuidString, privacy: .public), moving \(naming.count, privacy: .public) VMs to networks of their own"
        )
    }
}

extension NetworkKind {
    init(_ kind: VmnetNetworkKind) {
        switch kind {
        case .shared: self = .shared
        case .hostOnly: self = .hostOnly
        }
    }
}

extension VmnetNetworkKind {
    init(_ kind: NetworkKind) {
        switch kind {
        case .shared: self = .shared
        case .hostOnly: self = .hostOnly
        }
    }
}
