import AppIntents
import Foundation
import KernovaKit

/// One of the library's named networks, as Shortcuts names it.
///
/// Built from a ``NetworkSummary`` and the full read of each VM on it, so what
/// this surface shows can never drift from what the command core reads.
struct NetworkEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Network")

    static let defaultQuery = NetworkEntityQuery()

    /// The network's stable identifier, which every verb this surface runs
    /// addresses it by and a VM's Network Membership names.
    let id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Kind")
    var kind: VMNetworkKind

    @Property(title: "Virtual Machines")
    var members: [VMEntity]

    init(_ network: NetworkSummary, members: [VMEntity]) {
        self.id = network.id
        self.name = network.name
        self.kind = VMNetworkKind(network.kind)
        self.members = members
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: VMNetworkKind.caseDisplayRepresentations[kind]?.title)
    }
}

/// How Shortcuts finds the network an intent acts on.
///
/// Every method forwards to ``VMIntentGateway``, as ``VMEntityQuery``'s do: the
/// networks are few and fully enumerable, so `allEntities()` gives Shortcuts a
/// picker — and a Find Networks action — and a typed name resolves through a
/// case-insensitive contains match.
struct NetworkEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    static let findIntentDescription: IntentDescription? = IntentDescription(
        "Finds the library's named networks, each with the virtual machines on it.",
        categoryName: "Networks",
        resultValueName: "Networks")

    @Dependency private var gateway: VMIntentGateway

    func entities(for identifiers: [UUID]) async throws -> [NetworkEntity] {
        await gateway.networks(withIDs: identifiers)
    }

    func entities(matching string: String) async throws -> [NetworkEntity] {
        await gateway.networks(matching: string)
    }

    func allEntities() async throws -> [NetworkEntity] {
        await gateway.networks()
    }
}
