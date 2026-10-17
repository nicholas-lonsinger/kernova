import AppIntents
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The named-network half of the App Intents surface: how Shortcuts names a
/// network, and what each network verb dispatches.
///
/// Driven through the gateway rather than through the intents, which resolve
/// their `@Dependency` only inside a live intent session.
@Suite("VM Network Intent Tests", .caseScoped)
@MainActor
struct VMNetworkIntentTests {
    private func makeGateway(over harness: WiredCommandCore) -> VMIntentGateway {
        VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    // MARK: - Entity

    @Test("Every network kind is offered, named, and maps back to itself")
    func kindsMirrorEveryNetworkKind() {
        for kind in NetworkKind.allCases {
            let offered = VMNetworkKind(kind)
            #expect(offered.kind == kind)
            #expect(VMNetworkKind.caseDisplayRepresentations[offered] != nil)
        }
    }

    @Test("A network entity carries the summary, and reads its kind back in words")
    func entityDescribesItsSummary() throws {
        let network = NetworkSummary(id: UUID(), name: "Lab", kind: .hostOnly, members: [])

        let entity = NetworkEntity(network, members: [])

        #expect(entity.id == network.id)
        #expect(entity.name == "Lab")
        #expect(entity.kind == .hostOnly)
        #expect(String(localized: entity.displayRepresentation.title) == "Lab")
        let subtitle = try #require(entity.displayRepresentation.subtitle)
        #expect(String(localized: subtitle) == "Host Only")
    }

    @Test("A VM entity names the network it joins")
    func vmEntityNamesItsNetwork() {
        let id = UUID()
        let entity = VMEntity(
            VMIntentFixtures.info(
                networkMode: "nat", networkMembership: id.uuidString, networkName: .named("Lab")))

        #expect(entity.networkMembership == id.uuidString)
        #expect(entity.networkName == "Lab")
        #expect(VMEntity(VMIntentFixtures.info()).networkName == nil)
        #expect(
            VMEntity(VMIntentFixtures.info(networkMembership: id.uuidString, networkName: .unlisted(id)))
                .networkName == nil)
        #expect(
            VMEntity(VMIntentFixtures.info(networkMembership: id.uuidString, networkName: .unreadable))
                .networkName == "Network List Can\u{2019}t Be Read")
    }

    // MARK: - Lookup

    @Test("The networks list in the core's order, each VM on one read in full")
    func networksReadTheirMembersInFull() async throws {
        let harness = WiredCommandCore()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .nat)
        let test = try harness.core.createNetwork(name: "Test", kind: .hostOnly)
        let alpha = harness.register(name: "Alpha") {
            $0.networkMembership = .network(lab.id)
            $0.applyNetworkMode(.nat)
        }
        harness.register(name: "Beta")

        let networks = try await makeGateway(over: harness).networks()

        #expect(networks.map(\.id) == [lab.id, test.id])
        #expect(networks.map(\.kind) == [.nat, .hostOnly])
        #expect(networks[0].members.map(\.id) == [alpha.id])
        #expect(networks[0].members.map(\.name) == ["Alpha"])
        #expect(networks[0].members.map(\.networkName) == ["Lab"])
        #expect(networks[1].members.isEmpty)
    }

    @Test("Resolving by identifier, or by a typed name, answers only the networks asked for")
    func lookupFilters() async throws {
        let harness = WiredCommandCore()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .nat)
        let test = try harness.core.createNetwork(name: "Test Lab", kind: .hostOnly)
        let gateway = makeGateway(over: harness)

        #expect(try await gateway.networks(withIDs: [test.id, UUID()]).map(\.id) == [test.id])
        #expect(try await gateway.networks(matching: "lab").map(\.id) == [lab.id, test.id])
        #expect(try await gateway.networks(matching: "test").map(\.id) == [test.id])
    }

    // MARK: - Verbs

    @Test("A create reaches the core with the name and kind, and answers the network it listed")
    func createReachesTheCore() async throws {
        let harness = WiredCommandCore()

        let created = try await makeGateway(over: harness).createNetwork(name: "Lab", kind: .hostOnly)

        #expect(created.name == "Lab")
        #expect(created.kind == .hostOnly)
        let listed = try harness.core.networks()
        #expect(listed.map(\.id) == [created.id])
        #expect(listed.map(\.name) == ["Lab"])
        #expect(listed.map(\.kind) == [.hostOnly])
    }

    @Test("A rename and a delete address the network by identifier, never by name")
    func editsAddressByIdentifier() async throws {
        let harness = WiredCommandCore()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .nat)
        let spare = try harness.core.createNetwork(name: "Spare", kind: .nat)
        let gateway = makeGateway(over: harness)

        try await gateway.renameNetwork(lab.id, to: "Bench")
        #expect(try harness.core.networks().map(\.id) == [lab.id, spare.id])
        #expect(try harness.core.networks().map(\.name) == ["Bench", "Spare"])

        // Addressed by the identifier a rename leaves in place.
        try await gateway.deleteNetwork(lab.id)
        #expect(try harness.core.networks().map(\.id) == [spare.id])
    }

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async {
        let gateway = makeGateway(over: WiredCommandCore())
        let missing = UUID()

        await #expect(throws: CommandError.invalidArgument("A network needs a name.")) {
            try await gateway.createNetwork(name: " ", kind: .nat)
        }
        await #expect(
            throws: CommandError.itemNotFoundOnHost(item: "network named \u{201C}\(missing.uuidString)\u{201D}")
        ) {
            try await gateway.deleteNetwork(missing)
        }
    }
}
