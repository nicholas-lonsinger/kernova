import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Shut Down Anyway: offered where the guest's agents shut it down without
/// waiting for apps, asked on every use, and sent to the agent that offers it.
@Suite("Shut Down Anyway", .serialized, .caseScoped)
@MainActor
struct ShutDownAnywayTests {
    private let preferences = makeTestPreferences()

    /// The guest agents a running VM's hub sees.
    enum Agents: CaseIterable, CustomTestStringConvertible {
        /// A macOS guest's "For everyone" install: its session agent, and its
        /// system service offering shutdown without waiting for apps.
        case forEveryone
        /// A macOS guest's "Just for me" install: its session agent alone.
        case justForMe
        /// A Linux guest's session agent and system service, neither offering it.
        case linux
        /// A "For everyone" install whose system service is not connected.
        case systemServiceDisconnected

        var testDescription: String { "\(self)" }

        var guestOS: VMGuestOS { self == .linux ? .linux : .macOS }
        var canShutDownAnyway: Bool { self == .forEveryone }
    }

    private struct Fixture {
        let harness: WiredCommandCore.Scripted<MockVirtualizationService>
        let instance: VMInstance
        let probe: AgentHubProbe
        /// The system service's connection index, where one is connected.
        let system: Int?
    }

    nonisolated private static let consoleSession = PeerSessionState(
        console: .on, sessionID: "2", userName: "pbear")

    /// A running VM whose hub sees `agents`; the system service answers each
    /// power request with `answering`'s results.
    private func makeFixture(
        _ agents: Agents, phase: VMLifecyclePhase? = nil,
        answering: @escaping @Sendable (PowerAction) -> [PowerRequestResult] = { _ in
            [.accepted, .finished(.handedOff)]
        }
    ) async throws -> Fixture {
        let harness = WiredCommandCore.Scripted<MockVirtualizationService>(
            WiredCommandCore(virtualization: MockVirtualizationService(), preferences: preferences))
        let probe = AgentHubProbe()
        let instance = harness.wired.register(
            name: "Anyway", phase: phase ?? .running(sessionID: UUID()), guestOS: agents.guestOS,
            agentConnector: probe)
        instance.agentHub.attach(
            probe, policy: PolicySnapshot(), republisher: GuestLogRepublisher(vmLabel: instance.name))
        try await probe.changed.wait { probe.isStarted }

        let os: OSFamily = agents == .linux ? .linux : .macOS
        let sessionScope: InstallScope = agents == .justForMe ? .user : .system
        #expect(
            probe.connectPowerPeer(
                claim: PeerClaim(role: .sessionPeer, scope: sessionScope, os: os, architecture: .arm64),
                state: Self.consoleSession, answering: { _ in [.accepted, .finished(.handedOff)] }) != nil)
        var system: Int?
        switch agents {
        case .forEveryone, .linux:
            let offer =
                agents == .forEveryone
                ? PowerOffer(actions: [], ignoringApps: [.shutdown]) : PowerOffer(actions: [])
            system = probe.connectPowerPeer(
                claim: PeerClaim(role: .systemPeer, scope: .system, os: os, architecture: .arm64),
                state: PeerSessionState(console: .on, consoleSessionID: "2"), offer: offer, answering: answering)
            try await waitForChange { instance.agentHubSnapshot.peers.count == 2 }
        case .justForMe, .systemServiceDisconnected:
            try await waitForChange { instance.agentHubSnapshot.peers.count == 1 }
        }
        try await waitForChange { instance.agentHubSnapshot.power == .agent(.sessionPeer) }
        return Fixture(harness: harness, instance: instance, probe: probe, system: system)
    }

    private func shutDownAnyway(_ fixture: Fixture, consent: Consent) async throws {
        try await fixture.harness.core.stop(.id(fixture.instance.id), disposition: .anyway, consent: consent)
    }

    // MARK: - Where it is offered

    @Test(
        "Offered and enabled exactly where a connected system service of a macOS guest offers it",
        arguments: Agents.allCases)
    func offeredByAgents(agents: Agents) async throws {
        let fixture = try await makeFixture(agents)
        let capabilities = fixture.harness.library.capabilities
        #expect(fixture.instance.agentHubSnapshot.shutsDownIgnoringApps == agents.canShutDownAnyway)
        // One predicate answers every surface and the verb.
        #expect(capabilities.isApplicable(.shutDownAnyway, to: fixture.instance) == agents.canShutDownAnyway)
        #expect(capabilities.isAvailable(.shutDownAnyway, on: fixture.instance) == agents.canShutDownAnyway)
        #expect(capabilities.accepts(.shutDownAnyway, on: fixture.instance) == agents.canShutDownAnyway)
        #expect(
            capabilities.decision(.shutDownAnyway, on: fixture.instance, posture: .offer)
                == (agents.canShutDownAnyway ? .admit : nil))
    }

    @Test("A paused guest runs no agent: Shut Down Anyway is offered but not enabled")
    func pausedIsNotAvailable() async throws {
        let fixture = try await makeFixture(.forEveryone, phase: .livePaused(sessionID: UUID()))
        let capabilities = fixture.harness.library.capabilities
        #expect(capabilities.decision(.shutDownAnyway, on: fixture.instance, posture: .offer) == .refuse(.guestPaused))
        #expect(capabilities.isApplicable(.shutDownAnyway, to: fixture.instance))
        #expect(!capabilities.isAvailable(.shutDownAnyway, on: fixture.instance))
        #expect(!capabilities.accepts(.shutDownAnyway, on: fixture.instance))
    }

    @Test("A stopped VM offers no Shut Down Anyway, and its verb is refused by state")
    func stoppedIsNotApplicable() async throws {
        let harness = WiredCommandCore(virtualization: MockVirtualizationService(), preferences: preferences)
        let instance = harness.register(name: "Stopped", phase: .stopped, guestOS: .macOS)
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(peers: [], features: FeatureStatus.merge([]), shutsDownIgnoringApps: true))
        #expect(!harness.library.capabilities.isApplicable(.shutDownAnyway, to: instance))
        let error = try await #require(throws: CommandError.self) {
            try await harness.core.stop(.id(instance.id), disposition: .anyway, consent: .all)
        }
        guard case .invalidState = error else {
            Issue.record("Expected the state refusal, got \(error)")
            return
        }
    }

    // MARK: - The verb

    @Test("Without consent it asks, in the Force Stop sheet's terms, and sends nothing")
    func asksEveryTime() async throws {
        let fixture = try await makeFixture(.forEveryone)
        let error = try await #require(throws: CommandError.self) {
            try await shutDownAnyway(fixture, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt == VMCommandCore.shutDownAnywayPrompt(fixture.instance))
        #expect(prompt.kind == .shutDownAnyway)
        #expect(prompt.title == "Shut Down \u{201C}Anyway\u{201D} Anyway?")
        #expect(
            prompt.message
                == "macOS shuts down without waiting for apps. Apps still open quit without asking to save.")
        #expect(prompt.confirmTitle == "Shut Down Anyway")
        #expect(prompt.confirmIsDestructive)
        #expect(prompt.dismissTitle == "Cancel")
        #expect(prompt.alternatives.isEmpty)
        #expect(fixture.probe.powerRequests.isEmpty)
    }

    @Test("Its sheet offers Shut Down Anyway and Cancel, and neither takes Return")
    func sheetTakesNoReturn() {
        let harness = WiredCommandCore(virtualization: MockVirtualizationService(), preferences: preferences)
        let instance = harness.register(name: "Sheet", phase: .running(sessionID: UUID()), guestOS: .macOS)
        let config = AlertConfiguration(confirming: VMCommandCore.shutDownAnywayPrompt(instance), confirm: {})
        #expect(config.title == "Shut Down \u{201C}Sheet\u{201D} Anyway?")
        #expect(config.buttons.map(\.title) == ["Shut Down Anyway", "Cancel"])
        #expect(config.buttons.map(\.role) == [.destructive, .cancel])
        #expect(!config.buttons.contains { $0.role == .default })
    }

    @Test("With consent it asks the system service to shut down without waiting for apps, and presses no button")
    func sendsToTheSystemService() async throws {
        let fixture = try await makeFixture(.forEveryone)
        try await shutDownAnyway(fixture, consent: Consent([.shutDownAnyway]))
        #expect(fixture.probe.powerRequestsIgnoringApps.map(\.action) == [.shutdown])
        #expect(fixture.probe.powerRequests.count == 1)
        #expect(fixture.harness.virtualization.stopCallCount == 0)
    }

    @Test(
        "Where no agent offers it, it is refused naming the For everyone install, before any question and with nothing sent",
        arguments: Agents.allCases.filter { !$0.canShutDownAnyway })
    func refusedWithoutTheSystemService(agents: Agents) async throws {
        let fixture = try await makeFixture(agents)
        for consent in [Consent.none, .all] {
            let error = try await #require(throws: CommandError.self) {
                try await shutDownAnyway(fixture, consent: consent)
            }
            let requirement = try #require(error.stepRequirement, "\(error)")
            #expect(requirement.routes.isEmpty)
            #expect(requirement.message.contains("\u{201C}For everyone\u{201D}"))
        }
        #expect(fixture.probe.powerRequests.isEmpty)
        #expect(fixture.harness.virtualization.stopCallCount == 0)
    }

    @Test("A system service that refuses it leaves the guest as it was: the refusal, and no ACPI press")
    func untakenPressesNoButton() async throws {
        let fixture = try await makeFixture(.forEveryone) { _ in [.refused(WireError(.powerActionUnsupported))] }
        let error = try await #require(throws: CommandError.self) {
            try await shutDownAnyway(fixture, consent: .all)
        }
        #expect(error.stepRequirement?.message.contains("\u{201C}For everyone\u{201D}") == true)
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.instance.status == .running)
    }

    @Test("A paused guest's Shut Down Anyway names the resume, as its Stop does")
    func pausedNamesTheResume() async throws {
        let fixture = try await makeFixture(.forEveryone, phase: .livePaused(sessionID: UUID()))
        let error = try await #require(throws: CommandError.self) {
            try await shutDownAnyway(fixture, consent: .all)
        }
        #expect(error.stepRequirement?.routes.map(\.title) == ["Resume"])
        #expect(fixture.probe.powerRequests.isEmpty)
    }

    // MARK: - Doors

    @Test("Shortcuts' and AppleScript's stop methods each name the anyway disposition")
    func doorsNameTheDisposition() {
        #expect(VMStopMethod.shutDownAnyway.disposition == .anyway)
        #expect(VMStopMethod(.anyway) == .shutDownAnyway)
        #expect(Set(VMStopMethod.allCases.map(\.disposition)) == Set(StopDisposition.allCases))
        #expect(VMStopMethod.caseDisplayRepresentations[.shutDownAnyway] != nil)
    }

    @Test("Shortcuts' stop is refused for its consent without one, and sends it with one")
    func intentGatewayRoute() async throws {
        let fixture = try await makeFixture(.forEveryone)
        let gateway = VMIntentGateway(
            commands: fixture.harness.core, readiness: LibraryReadiness(awaitReady: {}), index: MockVMEntityIndex(),
            record: makeTestIndexRecord())
        let declined = try await #require(throws: CommandError.self) {
            try await gateway.stop(fixture.instance.id, disposition: .anyway, consent: .none)
        }
        #expect(declined.confirmationPrompt?.kind == .shutDownAnyway)
        #expect(fixture.probe.powerRequests.isEmpty)
        try await gateway.stop(fixture.instance.id, disposition: .anyway, consent: Consent([.shutDownAnyway]))
        #expect(fixture.probe.powerRequestsIgnoringApps.map(\.action) == [.shutdown])
    }
}
