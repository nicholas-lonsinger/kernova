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

    @Test("A stopped NAT VM is routed through all three changes, none discarding anything")
    func stoppedNATVMIsRoutedThroughEveryChange() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness)

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)
        let clone = harness.core.summary(vm)

        #expect(refused.title == "Duplicate MAC Address")
        #expect(
            refused.message
                == Self.shared
                + " Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network first: "
                + "move it to a network of its own, give it a new MAC address, or turn its networking off.")
        #expect(
            refused.routes == [
                StepRoute(
                    title: "Move to a Network of Its Own",
                    steps: [.setConfiguration(vm: clone, assignments: [Self.ownNetwork])], ending: .refusedVerb),
                StepRoute(
                    title: "Use a New MAC Address",
                    steps: [.setConfiguration(vm: clone, assignments: [Self.newAddress])], ending: .refusedVerb),
                StepRoute(
                    title: "Turn Off Networking",
                    steps: [.setConfiguration(vm: clone, assignments: [Self.noNetwork])], ending: .refusedVerb),
            ])
        #expect(harness.virtualization.startCallCount == 0)
    }

    private static let discardSentence =
        " A saved state does not restore under a new MAC address or without its network device, "
        + "so those changes discard \u{201C}Clone\u{201D}\u{2019}s saved state"

    private static let everyChange =
        " Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network first: "
        + "move it to a network of its own, give it a new MAC address, or turn its networking off."

    private static let ownNetworkOnly =
        " Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network first: "
        + "move it to a network of its own."

    private static let startsRatherThanResumes =
        " A new MAC address or no network device discards \u{201C}Clone\u{201D}\u{2019}s saved state, "
        + "so it then starts rather than resumes."

    @Test("A suspended NAT VM's start keeps its saved state only on a network of its own, and is told so")
    func suspendedNATVMIsToldWhatDiscards() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .suspended, savedState: true)

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)
        let clone = harness.core.summary(vm)

        #expect(
            refused.message
                == Self.shared + Self.discardSentence + "; a network of its own keeps it." + Self.everyChange)
        #expect(
            refused.routes.map(\.steps) == [
                [.setConfiguration(vm: clone, assignments: [Self.ownNetwork])],
                [.discardSavedState(vm: clone), .setConfiguration(vm: clone, assignments: [Self.newAddress])],
                [.discardSavedState(vm: clone), .setConfiguration(vm: clone, assignments: [Self.noNetwork])],
            ])
        #expect(refused.routes.map(\.discardsSavedState) == [false, true, true])
    }

    @Test("A suspended NAT VM's resume routes its discarding changes to the start they leave")
    func suspendedNATResumeRoutesItsDiscardsToAStart() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .suspended, savedState: true)

        let refused = try #require(
            try await #require(throws: CommandError.self) { try await harness.core.resume(.id(vm.id), consent: .none) }
                .stepRequirement)
        let clone = harness.core.summary(vm)

        #expect(refused.routes.map(\.ending) == [.refusedVerb, .start(vm: clone), .start(vm: clone)])
        #expect(
            refused.message
                == Self.shared + Self.discardSentence + "; a network of its own keeps it."
                + Self.startsRatherThanResumes + Self.everyChange)
    }

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

    @Test("A stopped Host Only VM, holding no saved state, is routed to a network of its own")
    func stoppedHostOnlyVMIsRoutedToItsOwnNetwork() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, mode: .hostOnly)

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)

        #expect(
            refused.routes.map(\.title) == [
                "Move to a Network of Its Own", "Use a New MAC Address", "Turn Off Networking",
            ])
    }

    @Test("Bridged has no network of its own to route to")
    func bridgedVMIsNotRoutedToItsOwnNetwork() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, mode: .bridged)

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)

        #expect(refused.routes.map(\.title) == ["Use a New MAC Address", "Turn Off Networking"])
    }

    @Test("A build that cannot attach a VM's own network does not route to one")
    func unentitledBuildDoesNotRouteToItsOwnNetwork() async throws {
        let harness = makeHarness(entitlements: .unentitled)
        let (vm, _) = try makePair(in: harness)

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)

        #expect(refused.routes.map(\.title) == ["Use a New MAC Address", "Turn Off Networking"])
    }

    @Test("An Ephemeral Mode VM on a warm baseline, holding a saved state, is offered no route that discards it")
    func warmBaselineWithholdsDiscardingRoutes() async throws {
        let harness = makeHarness()
        let baseline = VMSnapshot(name: "Baseline", kind: .warm, macAddress: Self.sharedMAC)
        let (vm, _) = try makePair(
            in: harness, phase: .suspended, savedState: true, snapshots: [baseline],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))
        #expect(vm.ephemeralBaselineSnapshot?.kind == .warm)

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)

        // Its discard is a revert to the baseline, which lands it suspended on
        // a saved state again, beside which the address and mode stay pinned.
        #expect(refused.routes.map(\.title) == ["Move to a Network of Its Own"])
        #expect(
            refused.message
                == Self.shared
                + " \u{201C}Clone\u{201D} is ephemeral, and discarding its saved state returns it to "
                + "\u{201C}Baseline\u{201D}, which holds one too, so a new MAC address or no network "
                + "device needs Ephemeral Mode turned off first."
                + Self.ownNetworkOnly)
    }

    @Test("A warm-baseline Ephemeral VM with no network of its own to move to is told what stands in the way")
    func warmBaselineHostOnlyNamesEphemeralMode() async throws {
        let harness = makeHarness()
        let baseline = VMSnapshot(name: "Baseline", kind: .warm, macAddress: Self.sharedMAC)
        let (vm, _) = try makePair(
            in: harness, mode: .hostOnly, phase: .suspended, savedState: true, snapshots: [baseline],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)

        #expect(refused.routes.isEmpty)
        #expect(
            refused.message
                == Self.shared
                + " \u{201C}Clone\u{201D} is ephemeral, and discarding its saved state returns it to "
                + "\u{201C}Baseline\u{201D}, which holds one too, so a new MAC address or no network "
                + "device needs Ephemeral Mode turned off first. Stop \u{201C}Source\u{201D} first.")
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
        guard case .conflict(_, _, .machineIdentity) = refused else {
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

    @Test("A bring-up nobody can be asked about is refused with the same routes")
    func unaskableStartIsRefusedWithRoutes() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness)

        do {
            try harness.core.startNow(vm, policy: .command(.unavailable))
            Issue.record("the unaskable start was admitted")
        } catch let refused as VMAdmissionRefusal {
            guard case .identityConflict(let conflict) = refused.refusal else {
                Issue.record("refused as \(refused.refusal)")
                return
            }
            #expect(!conflict.asks)
            let error = harness.core.commandError(for: refused.refusal, on: vm, verb: .start)
            #expect(error.stepRequirement?.routes.count == 3)
        }
    }

    // MARK: - Taking a Route

    @Test("Each route's steps, taken in order, let the start that was refused through")
    func eachRouteLetsTheStartThrough() async throws {
        for index in 0..<3 {
            let harness = makeHarness()
            let (vm, _) = try makePair(in: harness)
            let refused = try #require(
                try await #require(throws: CommandError.self) {
                    try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
                }.stepRequirement)
            let route = refused.routes[index]

            for step in route.steps { try await harness.core.take(step) }
            try await harness.core.start(.id(vm.id), recovery: false, consent: .none)

            #expect(harness.virtualization.startCallCount == 1, "\(route.title)")
        }
    }

    @Test("A network of its own keeps a suspended NAT VM's saved state, which the resume restores")
    func ownNetworkRouteKeepsTheSavedState() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .suspended, savedState: true)
        let refused = try #require(
            try await #require(throws: CommandError.self) { try await harness.core.resume(.id(vm.id), consent: .none) }
                .stepRequirement)

        for step in refused.routes[0].steps { try await harness.core.take(step) }
        try await harness.core.resume(.id(vm.id), consent: .none)

        #expect(vm.configuration.networkMembership == .isolated)
        #expect(harness.virtualization.lastStartRoute == .restoredSavedState)
    }

    @Test("A route that discards the saved state leaves the VM stopped, and the start asked again boots it")
    func discardingRouteLeavesTheVMStopped() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .suspended, savedState: true)
        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
            }.stepRequirement)

        for step in refused.routes[1].steps { try await harness.core.take(step) }

        #expect(!vm.hasSaveFile)
        #expect(vm.configuration.macAddress != Self.sharedMAC)
        try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
        #expect(harness.virtualization.lastStartRoute == .coldBoot)
    }

    // MARK: - Restart

    @Test("Restart is refused before the guest goes down, routed only to a network of its own")
    func restartOffersOnlyItsOwnNetwork() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .running(sessionID: UUID()))

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.restart(.id(vm.id), timeout: nil, consent: .none)
            }.stepRequirement)
        #expect(
            refused.routes == [
                StepRoute(
                    title: "Move to a Network of Its Own",
                    steps: [.setConfiguration(vm: harness.core.summary(vm), assignments: [Self.ownNetwork])],
                    ending: .refusedVerb)
            ])
        #expect(
            refused.message
                == Self.shared
                + " Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network first: "
                + "move it to a network of its own.")
        #expect(harness.virtualization.stopCallCount == 0)

        for step in refused.routes[0].steps { try await harness.core.take(step) }
        try await harness.core.restart(.id(vm.id), timeout: nil, consent: .none)

        #expect(harness.virtualization.stopCallCount == 1)
        #expect(vm.configuration.networkMembership == .isolated)
    }

    @Test("An Ephemeral Mode VM's restart is routed nowhere: its power-off reverts the move")
    func ephemeralRestartHasNoRoutes() async throws {
        let harness = makeHarness()
        let baseline = VMSnapshot(name: "Baseline", kind: .cold, macAddress: Self.sharedMAC)
        let (vm, _) = try makePair(
            in: harness, phase: .running(sessionID: UUID()), snapshots: [baseline],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.restart(.id(vm.id), timeout: nil, consent: .none)
            }.stepRequirement)

        #expect(refused.routes.isEmpty)
        #expect(
            refused.message
                == Self.shared
                + " \u{201C}Clone\u{201D} is ephemeral, so a restart returns it to \u{201C}Baseline\u{201D}, "
                + "network included, before it starts again. Stop \u{201C}Source\u{201D} first.")
        #expect(harness.virtualization.stopCallCount == 0)
    }

    // MARK: - Revert

    @Test("A revert that would resume onto a used address is refused with no route, naming the order that works")
    func revertHasNoRoutes() async throws {
        let harness = makeHarness()
        RegisteredVMInstanceFixture.register(
            name: "Holder", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.macAddress = Self.sharedMAC
        }
        let reverting = RegisteredVMInstanceFixture.register(
            name: "Reverting", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.macAddress = "02:4b:4e:56:0c:02"
        }
        let snapshot = VMSnapshot(name: "Before", kind: .warm, macAddress: Self.sharedMAC)
        reverting.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        var captured = reverting.configuration
        captured.macAddress = Self.sharedMAC
        harness.machineFiles.setCapturedConfiguration(captured, for: snapshot.id)

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.revertToSnapshot(
                    .id(reverting.id), snapshot: snapshot.id, consent: .all)
            }.stepRequirement)

        #expect(refused.title == "Duplicate MAC Address")
        #expect(refused.routes.isEmpty)
        #expect(
            refused.message
                == "\u{201C}Reverting\u{201D} has the same MAC address as \u{201C}Holder\u{201D}, which is active. "
                + "Two virtual machines with the same MAC address must not run on the same network at once. "
                + "Stop \u{201C}Holder\u{201D} first, or stop \u{201C}Reverting\u{201D} and then revert it: "
                + "it comes back suspended, and its network can be changed before it resumes.")
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(reverting.status == .running)
    }

    @Test("A revert is judged on the network its snapshot lands the VM on, not the one it is on now")
    func revertIsJudgedOnTheSnapshotsNetwork() async throws {
        let harness = makeHarness()
        RegisteredVMInstanceFixture.register(
            name: "B", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = Self.sharedMAC
        }
        let a = RegisteredVMInstanceFixture.register(
            name: "A", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.networkMembership = .isolated
            $0.macAddress = Self.sharedMAC
        }
        var captured = a.configuration
        captured.networkMembership = .common
        let snapshot = VMSnapshot(
            name: "On common", kind: .warm, macAddress: Self.sharedMAC,
            network: VMCapturedNetwork(captured))
        a.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        harness.machineFiles.setCapturedConfiguration(captured, for: snapshot.id)

        let refused = try #require(
            try await #require(throws: CommandError.self) {
                try await harness.core.revertToSnapshot(
                    .id(a.id), snapshot: snapshot.id, consent: .all)
            }.stepRequirement)

        #expect(refused.title == "Duplicate MAC Address")
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
        #expect(a.configuration.networkMembership == .isolated)
    }

    // MARK: - Live Edit

    /// Clone running on Host Only at `membership` and Source running on NAT's
    /// common network, both at ``sharedMAC`` — admitted, the networks being
    /// different.
    private func makeLivePair(
        in harness: Harness, membership: VMNetworkMembership = .common
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: "Source", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = Self.sharedMAC
        }
        return RegisteredVMInstanceFixture.register(
            name: "Clone", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.networkMode = .hostOnly
            $0.networkMembership = membership
            $0.macAddress = Self.sharedMAC
        }
    }

    @Test("A live mode switch onto a used network is routed to a network of its own, then lands")
    func liveSwitchIsRoutedToItsOwnNetwork() async throws {
        let harness = makeHarness()
        let vm = makeLivePair(in: harness)
        let toNAT = [ConfigurationEntry(key: "network.mode", value: "nat")]

        let refused = try #require(
            try #require(throws: CommandError.self) {
                _ = try harness.core.setConfiguration(.id(vm.id), assignments: toNAT, consent: .none)
            }.stepRequirement)

        #expect(refused.title == "Duplicate MAC Address")
        #expect(
            refused.message
                == Self.shared + " Move \u{201C}Clone\u{201D} to a network of its own first, then make this change.")
        #expect(
            refused.routes == [
                StepRoute(
                    title: "Join a Network of Its Own",
                    steps: [.setConfiguration(vm: harness.core.summary(vm), assignments: [Self.ownNetwork])],
                    ending: .refusedVerb)
            ])
        #expect(vm.configuration.networkMode == .hostOnly)

        for step in refused.routes[0].steps { try await harness.core.take(step) }
        try harness.core.setConfiguration(.id(vm.id), assignments: toNAT, consent: .none)

        #expect(vm.configuration.networkMode == .nat)
        #expect(vm.configuration.networkMembership == .isolated)
    }

    @Test("A live write that moves the membership itself is refused as the plain conflict")
    func liveMembershipWriteHasNoRoute() async throws {
        let harness = makeHarness()
        let vm = makeLivePair(in: harness, membership: .isolated)

        let error = try #require(throws: CommandError.self) {
            _ = try harness.core.setConfiguration(
                .id(vm.id),
                assignments: [
                    ConfigurationEntry(key: "network.mode", value: "nat"),
                    ConfigurationEntry(key: "network.membership", value: "common"),
                ],
                consent: .none)
        }

        #expect(error.stepRequirement == nil)
        #expect(error.isConflict)
    }

    @Test("A running VM taken off its own network onto a used one is refused with no route back")
    func leavingItsOwnNetworkOffersNoWayBack() throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .running(sessionID: UUID()))
        try harness.core.setConfiguration(
            .id(vm.id), assignments: [Self.ownNetwork], consent: .none)

        let error = try #require(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .id(vm.id),
                assignments: [ConfigurationEntry(key: "network.membership", value: "common")],
                consent: .none)
        }
        #expect(error.stepRequirement == nil)
        #expect(error.isConflict)
        #expect(vm.configuration.networkMembership == .isolated)
    }
}

extension CommandError {
    /// Whether this is the plain conflict refusal, offering nothing.
    fileprivate var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }
}
