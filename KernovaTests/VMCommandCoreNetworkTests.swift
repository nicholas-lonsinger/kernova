import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The named-network verbs against a real library.
@Suite("VMCommandCore Network Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreNetworkTests {
    private let preferences = makeTestPreferences()

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
    }

    private func makeHarness(entitlements: EntitlementService = .entitled) -> Harness {
        let storage = MockVMStorageService()
        let fileSystem = MockFileSystem()
        let lifecycle = makeTestLifecycle(
            virtualization: MockVirtualizationService(), fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: MockVMBundleMachineFiles(), lifecycle: lifecycle,
            fileSystem: fileSystem, preferences: preferences, entitlements: entitlements)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: preferences)
        return Harness(core: core, library: library)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String, phase: VMLifecyclePhase = .stopped,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: .linux, library: harness.library,
            preferences: preferences,
            mutate: {
                mutate(&$0)
                if $0.networkMembership != .common { $0.applyNetworkMode($0.networkMode) }
            })
    }

    @Test("A VM joins a network through network.membership, and the listing names its members")
    func membersJoinThroughTheirMembershipKey() throws {
        let harness = makeHarness()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .hostOnly)
        let alpha = makeInstance(in: harness, name: "Alpha")
        makeInstance(in: harness, name: "Beta")

        try harness.core.setConfiguration(
            .id(alpha.instanceID),
            assignments: [
                ConfigurationEntry(key: "network.mode", value: "hostOnly"),
                ConfigurationEntry(key: "network.membership", value: "Lab"),
            ], consent: .none)

        #expect(try harness.core.networks().map(\.members) == [[harness.core.summary(alpha)]])
        #expect(try harness.core.info(.id(alpha.instanceID)).networkName == .named("Lab"))
        #expect(lab.kind == .hostOnly)
        try harness.core.renameNetwork("lab", to: "Bench")
        #expect(try harness.core.info(.id(alpha.instanceID)).networkName == .named("Bench"))
    }

    @Test("Deleting a network moves every VM naming it to a network of its own")
    func deleteMovesMembersToNetworksOfTheirOwn() throws {
        let harness = makeHarness()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .nat)
        let member = makeInstance(in: harness, name: "Member") {
            $0.networkMembership = .network(lab.id)
        }
        let bridged = makeInstance(in: harness, name: "Bridged") {
            $0.networkMode = .bridged
            $0.networkMembership = .network(lab.id)
        }
        let bystander = makeInstance(in: harness, name: "Bystander")

        try harness.core.deleteNetwork(lab.id.uuidString)

        #expect(try harness.core.networks().isEmpty)
        #expect(member.configuration.networkMembership == .isolated)
        #expect(bridged.configuration.networkMembership == .isolated)
        #expect(bystander.configuration.networkMembership == .common)
        #expect(throws: CommandError.self) { try harness.core.deleteNetwork("Lab") }
    }

    @Test("A member whose state takes no move refuses the whole delete")
    func aRefusedMoveKeepsTheNetwork() throws {
        let harness = makeHarness()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .hostOnly)
        let stopped = makeInstance(in: harness, name: "Stopped") {
            $0.networkMode = .hostOnly
            $0.networkMembership = .network(lab.id)
        }
        // A suspended Host Only VM's saved state is not known to restore on
        // another network, so its membership is pinned.
        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended) {
            $0.networkMode = .hostOnly
            $0.networkMembership = .network(lab.id)
        }
        try VMInstanceFixture.writeSaveFile(for: suspended)

        #expect(throws: CommandError.self) { try harness.core.deleteNetwork("Lab") }
        #expect(try harness.core.networks().map(\.id) == [lab.id])
        #expect(stopped.configuration.networkMembership == .network(lab.id))
    }

    @Test("A build that cannot attach a named network refuses to create one")
    func anUnentitledBuildCreatesNone() {
        let harness = makeHarness(entitlements: .unentitled)
        #expect(throws: CommandError.unsupportedByBuild(capability: "named networks")) {
            try harness.core.createNetwork(name: "Lab", kind: .nat)
        }
    }

    @Test("A VM naming the network whose membership is inert never holds up the delete")
    func anInertNamerDoesNotBlockTheDelete() throws {
        let harness = makeHarness()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .hostOnly)
        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended) {
            $0.networkMode = .bridged
            $0.networkMembership = .network(lab.id)
        }
        try VMInstanceFixture.writeSaveFile(for: suspended)

        try harness.core.deleteNetwork("Lab")

        #expect(try harness.core.networks().isEmpty)
        // Its state takes no write; it names an unlisted network until it does.
        #expect(suspended.configuration.networkMembership == .network(lab.id))
    }
}
