import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A bring-up refused over a MAC address another active VM uses on its network
/// names the changes to the VM's network it can take first, each a step of its
/// own, and is taken once one of them lands.
@Suite("VMCommandCore MAC Conflict Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreMACConflictTests {
    private let preferences = makeTestPreferences()

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>

    private func makeHarness(entitlements: EntitlementService = .entitled) -> Harness {
        Harness(
            WiredCommandCore(
                virtualization: MockVirtualizationService(), entitlements: entitlements, preferences: preferences))
    }

    private static let sharedMAC = "02:4b:4e:56:0c:01"

    /// An active VM on `mode`'s common network at ``sharedMAC``, and a second
    /// VM in `phase` carrying the same address on the same network.
    @discardableResult
    private func makePair(
        in harness: Harness, mode: VMNetworkMode = .nat,
        phase: VMLifecyclePhase = .stopped, savedState: Bool = false,
        identity: Data? = nil, snapshots: [VMSnapshot] = [], hostState: VMHostState = VMHostState()
    ) throws -> (vm: VMInstance, other: VMInstance) {
        let other = RegisteredVMInstanceFixture.register(
            name: "Source", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.networkMode = mode
            $0.macAddress = Self.sharedMAC
            $0.genericMachineIdentifierData = identity
        }
        let vm = RegisteredVMInstanceFixture.register(
            name: "Clone", phase: phase, guestOS: .linux, snapshots: snapshots,
            library: harness.library, preferences: preferences, hostState: hostState
        ) {
            $0.networkEnabled = true
            $0.networkMode = mode
            $0.macAddress = Self.sharedMAC
            $0.genericMachineIdentifierData = identity
        }
        if savedState { try VMInstanceFixture.writeSaveFile(for: vm) }
        return (vm, other)
    }

    /// The sentences every refusal of Clone beside Source opens with.
    private static let shared =
        "\u{201C}Clone\u{201D} has the same MAC address as \u{201C}Source\u{201D}, which is active. "
        + "Two virtual machines with the same MAC address must not run on the same network at once."

    private static let ownNetwork = ConfigurationEntry(key: "network.membership", value: "isolated")
    private static let newAddress = ConfigurationEntry(key: "network.mac", value: "new")
    private static let noNetwork = ConfigurationEntry(key: "network.mode", value: "none")

    // MARK: - Routes

    private static let discardSentence =
        " A saved state does not restore under a new MAC address or without its network device, "
        + "so those changes discard \u{201C}Clone\u{201D}\u{2019}s saved state"

    private static let everyChange =
        " Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network first: "
        + "move it to a network of its own, give it a new MAC address, or turn its networking off."

    private static let startsRatherThanResumes =
        " A new MAC address or no network device discards \u{201C}Clone\u{201D}\u{2019}s saved state, "
        + "so it then starts rather than resumes."

    @Test("A suspended Host Only VM is not routed to a network of its own, which no restore was measured on")
    func suspendedHostOnlyVMIsNotRoutedToItsOwnNetwork() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, mode: .hostOnly, phase: .suspended, savedState: true)

        let started = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)
        #expect(started.routes.map(\.title) == ["Use a New MAC Address", "Turn Off Networking"])
        #expect(started.routes.allSatisfy { $0.discardsSavedState })
        #expect(
            started.message
                == Self.shared + Self.discardSentence + "."
                + " Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network first: "
                + "give it a new MAC address or turn its networking off.")

        // A resume is routed through the same changes, each ending in the
        // start a discard leaves, and taking one then starting succeeds.
        let resumed = try #require(
            try await #require(throws: CommandError.self) { try await harness.core.resume(.id(vm.id), consent: .none) }
                .stepRequirement)
        let clone = harness.core.summary(vm)
        #expect(resumed.routes.map(\.title) == ["Use a New MAC Address", "Turn Off Networking"])
        #expect(resumed.routes.map(\.ending) == [.start(vm: clone), .start(vm: clone)])
        #expect(
            resumed.message
                == Self.shared + Self.discardSentence + "." + Self.startsRatherThanResumes
                + " Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network first: "
                + "give it a new MAC address or turn its networking off.")

        for step in resumed.routes[0].steps { try await harness.core.take(step) }
        try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
        #expect(harness.virtualization.lastStartRoute == .coldBoot)
        #expect(vm.configuration.macAddress != Self.sharedMAC)
    }

    @Test("A cold-baseline Ephemeral VM's discarding routes say the session's changes go with its saved state")
    func coldBaselineDisclosesTheRevert() async throws {
        let harness = makeHarness()
        let baseline = VMSnapshot(name: "Baseline", kind: .cold, macAddress: Self.sharedMAC)
        let (vm, _) = try makePair(
            in: harness, phase: .suspended, savedState: true, snapshots: [baseline],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))
        let clone = harness.core.summary(vm)
        let ephemeral =
            " \u{201C}Clone\u{201D} is ephemeral, so it returns to \u{201C}Baseline\u{201D}. "
            + "The suspended session, and everything changed inside the guest during it, are discarded."

        let resumed = try #require(
            try await #require(throws: CommandError.self) { try await harness.core.resume(.id(vm.id), consent: .none) }
                .stepRequirement)
        #expect(resumed.routes.map(\.ending) == [.refusedVerb, .start(vm: clone), .start(vm: clone)])
        #expect(
            resumed.message
                == Self.shared + Self.discardSentence + "; a network of its own keeps it." + ephemeral
                + Self.startsRatherThanResumes + Self.everyChange)

        let started = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)
        #expect(
            started.message
                == Self.shared + Self.discardSentence + "; a network of its own keeps it." + ephemeral
                + Self.everyChange)
        #expect(
            started.routes.map(\.steps) == [
                [.setConfiguration(vm: clone, assignments: [Self.ownNetwork])],
                [.discardSavedState(vm: clone), .setConfiguration(vm: clone, assignments: [Self.newAddress])],
                [.discardSavedState(vm: clone), .setConfiguration(vm: clone, assignments: [Self.noNetwork])],
            ])
    }

    @Test("A machine ID shared alongside the MAC address is answered first, so no route discards before it")
    func sharedMachineIdentityIsAnsweredBeforeTheRoute() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(
            in: harness, phase: .suspended, savedState: true, identity: Data([3, 1, 4]))

        // The setting off: the machine ID refuses outright, and nothing is
        // routed or written.
        let refused = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(vm.id), recovery: false, consent: .all)
        }
        guard case .conflict(_, _, .machineIdentity(overrideSettingOn: false)) = refused else {
            Issue.record("refused as \(refused)")
            return
        }
        #expect(vm.hasSaveFile)
        #expect(vm.configuration.macAddress == Self.sharedMAC)

        // The setting on: the confirmation comes first, then the route.
        preferences.allowsDuplicateMachineIDOverride = true
        let asked = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
        }
        #expect(asked.confirmationPrompt?.kind == .startBesideSharedMachineIdentity)
        let routed = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(
                    .id(vm.id), recovery: false, consent: Consent([.startBesideSharedMachineIdentity]))
            }.stepRequirement)
        #expect(routed.routes.count == 3)
        #expect(vm.hasSaveFile)
        #expect(harness.virtualization.startCallCount == 0)
    }
}
