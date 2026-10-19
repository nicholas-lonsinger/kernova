import Foundation
import KernovaKit
import KernovaLogging

/// The named-network verbs: the library's networks, which a VM joins through
/// its `network.membership` key.
extension VMCommandCore {
    // MARK: - Reads

    /// The library's named networks, ordered by name, each with the VMs on it.
    ///
    /// Addresses no VM: a network is the library's, and a VM joins one through
    /// its `network.membership` key. Refuses while the library's list of
    /// networks cannot be read, rather than answering none.
    package func networks() throws -> [NetworkSummary] {
        library.networks.reload()
        return try library.networks.listedNetworks(verb: .networks).map(summary)
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

    /// Lists a new network named `name`, whose VMs run in `kind`. Refuses a
    /// name another network has, ignoring case, and one a membership value
    /// already spells.
    @discardableResult
    package func createNetwork(name: String, kind: NetworkKind) throws -> NetworkSummary {
        library.networks.reload()
        let kind = VmnetNetworkKind(kind)
        let probe = VMJoinedNetwork.vmnet(VmnetNetworkID(kind: kind, scope: .named(UUID())))
        guard library.entitlements.canAttach(probe) else {
            throw CommandError.unsupportedByBuild(capability: probe.entitledCapability)
        }
        let network = try library.networks.create(name: name, kind: kind, verb: .createNetwork)
        logger.log(
            .notice,
            "Created the \(kind.rawValue, privacy: .public) network \(network.id.uuidString, privacy: .public)"
        )
        return summary(network)
    }

    /// Renames the network `network` names, by identifier or by name. A VM
    /// names its network by identifier, so no VM changes.
    package func renameNetwork(_ network: String, to newName: String) throws {
        library.networks.reload()
        let network = try library.networks.requireNetwork(named: network, verb: .renameNetwork)
        try library.networks.rename(network.id, to: newName, verb: .renameNetwork)
        logger.log(.notice, "Renamed the network \(network.id.uuidString, privacy: .public)")
    }

    /// Stops listing the network `network` names.
    ///
    /// Refuses while a VM is set to join it: with the VM's own refusal when a
    /// member's state takes no change of membership, else with
    /// ``CommandError/stepRequired(_:)``, routing each VM to a network of its
    /// own, which narrows what it reaches and widens nothing
    /// (docs/NETWORKING.md). An inert VM whose state takes no such change, and
    /// a snapshot taken on the network, keep naming it, unlisted.
    package func deleteNetwork(_ network: String) throws {
        library.networks.reload()
        let network = try library.networks.requireNetwork(named: network, verb: .deleteNetwork)
        let key = VMConfigurationKeyRegistry.networkMembership
        let isolated = VMNetworkMembership.isolated.rawValue
        let naming = library.instances.filter {
            $0.configuration.networkMembership == .network(network.id)
        }
        // Every member moves first. A VM naming it whose membership is inert —
        // Bridged, or no device — moves only where its state takes the write,
        // since nothing it reaches changes either way; the rest keep naming it,
        // unlisted.
        let members = naming.filter { library.networks.network(joinedBy: $0.configuration) == network }
        // A member that cannot move refuses the delete with its own refusal, so
        // a route is offered only when every step in it would be taken.
        for instance in members
        where !capabilities.isAvailable(key, writing: isolated, on: instance) {
            try requireGates(for: [(key: key, value: isolated)], on: instance)
            var settings = instance.settings
            try key.apply(
                isolated, to: &settings,
                context: VMConfigurationWriteContext(
                    instance, entitlements: library.entitlements,
                    networks: library.networks.state,
                    resourceLimits: library.virtualizationHost.resourceLimits))
        }
        let joining = naming.filter { instance in
            members.contains { $0 === instance }
                || capabilities.isAvailable(key, writing: isolated, on: instance)
        }
        if !joining.isEmpty {
            let names = DataFormatters.quotedList(joining.map(\.name))
            let message =
                joining.count == 1
                ? "\(names) is set to join \u{201C}\(network.name)\u{201D}. Move it to another network first, then delete \u{201C}\(network.name)\u{201D}."
                : "\(names) are set to join \u{201C}\(network.name)\u{201D}. Move each to another network first, then delete \u{201C}\(network.name)\u{201D}."
            throw CommandError.stepRequired(
                StepRequirement(
                    message: message,
                    routes: [
                        StepRoute(
                            title: joining.count == 1
                                ? "Move to a Network of Its Own" : "Move Each to a Network of Its Own",
                            steps: joining.map {
                                .setConfiguration(
                                    vm: summary($0), assignments: [key.assigning(isolated)])
                            }, ending: .refusedVerb)
                    ]))
        }
        // A filter naming the network keeps naming it, and admits no VM from
        // here on: one naming a network the library does not list is on
        // ``VMLibraryFilter/Network/unlisted``, never on the network itself.
        try library.networks.remove(network.id, verb: .deleteNetwork)
        logger.log(
            .notice,
            "Deleted the network \(network.id.uuidString, privacy: .public)"
        )
    }
}

extension NetworkKind {
    package init(_ kind: VmnetNetworkKind) {
        switch kind {
        case .nat: self = .nat
        case .hostOnly: self = .hostOnly
        }
    }
}

extension VmnetNetworkKind {
    package init(_ kind: NetworkKind) {
        switch kind {
        case .nat: self = .nat
        case .hostOnly: self = .hostOnly
        }
    }
}
