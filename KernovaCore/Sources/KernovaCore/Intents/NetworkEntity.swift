import AppIntents
import Foundation
import KernovaCommandModel

/// One of the library's named networks, as Shortcuts names it.
///
/// Built from a ``NetworkSummary`` and the full read of each VM on it.
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

    /// The entity `network` describes, accounting for each
    /// ``NetworkSummary/Field``, with `member` the full read of a VM it
    /// lists, `nil` for one with none.
    init(_ network: NetworkSummary, member: (VMSummary) -> VMEntity?) {
        self.id = network.id
        for field in NetworkSummary.Field.allCases {
            switch field {
            case .id: break  // The entity's identifier, set above.
            case .name: name = network.name
            case .kind: kind = VMNetworkKind(network.kind)
            case .members: members = network.members.compactMap(member)
            }
        }
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
        try await gateway.networks(withIDs: identifiers)
    }

    func entities(matching string: String) async throws -> [NetworkEntity] {
        try await gateway.networks(matching: string)
    }

    func allEntities() async throws -> [NetworkEntity] {
        try await gateway.networks()
    }
}
