import AppIntents
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The named-network half of the App Intents surface: how Shortcuts names a
/// network, and what each network verb dispatches.
///
/// Driven through the gateway rather than through the intents, which resolve
/// their `@Dependency` only inside a live intent session.
@Suite("VM Network Intent Tests", .caseScoped)
@MainActor
struct VMNetworkIntentTests {
    private func makeGateway(_ commands: MockVMCommanding) -> VMIntentGateway {
        VMIntentGateway(
            commands: commands, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    private func makeSummary(name: String) -> VMSummary {
        VMSummary(id: UUID(), name: name, status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)
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
                networkMode: "shared", networkMembership: id.uuidString, networkName: .named("Lab")))

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
        let commands = MockVMCommanding()
        let alpha = makeSummary(name: "Alpha")
        commands.library = [alpha, makeSummary(name: "Beta")]
        let lab = NetworkSummary(id: UUID(), name: "Lab", kind: .shared, members: [alpha])
        let test = NetworkSummary(id: UUID(), name: "Test", kind: .hostOnly, members: [])
        commands.networksToReturn = [lab, test]

        let networks = try await makeGateway(commands).networks()

        #expect(networks.map(\.id) == [lab.id, test.id])
        #expect(networks.map(\.kind) == [.shared, .hostOnly])
        #expect(networks[0].members.map(\.id) == [alpha.id])
        #expect(networks[0].members.map(\.name) == ["Alpha"])
        #expect(networks[1].members.isEmpty)
    }

    @Test("Resolving by identifier, or by a typed name, answers only the networks asked for")
    func lookupFilters() async throws {
        let commands = MockVMCommanding()
        let lab = NetworkSummary(id: UUID(), name: "Lab", kind: .shared, members: [])
        let test = NetworkSummary(id: UUID(), name: "Test Lab", kind: .hostOnly, members: [])
        commands.networksToReturn = [lab, test]
        let gateway = makeGateway(commands)

        #expect(try await gateway.networks(withIDs: [test.id, UUID()]).map(\.id) == [test.id])
        #expect(try await gateway.networks(matching: "lab").map(\.id) == [lab.id, test.id])
        #expect(try await gateway.networks(matching: "test").map(\.id) == [test.id])
    }

    // MARK: - Verbs

    @Test("A create reaches the core with the name and kind, and answers the network it listed")
    func createReachesTheCore() async throws {
        let commands = MockVMCommanding()

        let created = try await makeGateway(commands).createNetwork(name: "Lab", kind: .hostOnly)

        #expect(commands.createNetworkCalls.map(\.name) == ["Lab"])
        #expect(commands.createNetworkCalls.map(\.kind) == [.hostOnly])
        #expect(created.name == "Lab")
        #expect(created.kind == .hostOnly)
        #expect(commands.networksToReturn.map(\.id) == [created.id])
    }

    @Test("A rename and a delete address the network by identifier, never by name")
    func editsAddressByIdentifier() async throws {
        let commands = MockVMCommanding()
        let gateway = makeGateway(commands)
        let id = UUID()

        try await gateway.renameNetwork(id, to: "Lab")
        try await gateway.deleteNetwork(id)

        #expect(commands.renameNetworkCalls.map(\.network) == [id.uuidString])
        #expect(commands.renameNetworkCalls.map(\.newName) == ["Lab"])
        #expect(commands.deleteNetworkCalls == [id.uuidString])
    }

    @Test("A refusal from the core reaches the caller unchanged")
    func refusalsPassThrough() async {
        let commands = MockVMCommanding()
        let refusal = CommandError.invalidArgument("A network needs a name.")
        commands.networkError = refusal
        let gateway = makeGateway(commands)

        await #expect(throws: refusal) {
            try await gateway.createNetwork(name: " ", kind: .shared)
        }
        await #expect(throws: refusal) {
            try await gateway.deleteNetwork(UUID())
        }
    }
}
