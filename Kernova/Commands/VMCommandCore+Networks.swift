import Foundation
import KernovaKit
import KernovaLogging

/// The named-network verbs: the library's networks, which a VM joins through
/// its `network.membership` key.
extension VMCommandCore {
    // MARK: - Reads

    func networks() -> [NetworkSummary] {
        library.networks.reload()
        return library.networks.networks.map(summary)
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
        library.networks.reload()
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
        library.networks.reload()
        let network = try library.networks.requireNetwork(named: network)
        try library.networks.rename(network.id, to: newName, verb: .renameNetwork)
        #log(Self.logger, .notice, "Renamed the network \(network.id.uuidString, privacy: .public)")
    }

    func deleteNetwork(_ network: String) throws {
        library.networks.reload()
        let network = try library.networks.requireNetwork(named: network)
        let key = VMConfigurationKeyRegistry.networkMembership
        let isolated = VMNetworkMembership.isolated.rawValue
        let naming = library.instances.filter {
            $0.configuration.networkMembership == .network(network.id)
        }
        // The VMs on it move or the delete is refused. A VM naming it whose
        // membership is inert — Bridged, or no device — moves only where its
        // state takes the write, since nothing it reaches changes either way.
        let members = naming.filter { library.networks.network(joinedBy: $0.configuration) == network }
        for instance in members
        where !capabilities.isAvailable(key, writing: isolated, on: instance) {
            try requireGates(for: [(key: key, value: isolated)], on: instance)
            var settings = instance.settings
            try key.apply(
                isolated, to: &settings,
                context: VMConfigurationWriteContext(
                    instance, entitlements: library.entitlements,
                    networks: library.networks.networks))
        }
        let inert = naming.filter { instance in
            !members.contains { $0 === instance }
                && capabilities.isAvailable(key, writing: isolated, on: instance)
        }
        for instance in members + inert {
            try setConfiguration(
                .id(instance.instanceID), assignments: [key.assigning(isolated)], consent: .none)
        }
        try library.networks.remove(network.id, verb: .deleteNetwork)
        #log(
            Self.logger, .notice,
            "Deleted the network \(network.id.uuidString, privacy: .public), moving \(members.count + inert.count, privacy: .public) VMs to networks of their own"
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
