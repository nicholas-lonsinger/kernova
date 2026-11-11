import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Stop Anyway and Restart Anyway: offered where the guest's agents shut it
/// down without waiting for apps, asked on every use, and sent to the agent
/// that offers it — Restart Anyway then booting the guest once it is off.
@Suite("Stop Anyway and Restart Anyway", .serialized, .caseScoped)
@MainActor
struct StopAnywayTests {
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
        var canStopAnyway: Bool { self == .forEveryone }
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

    private func stopAnyway(_ fixture: Fixture, consent: Consent) async throws {
        try await fixture.harness.core.stop(.id(fixture.instance.id), disposition: .anyway, consent: consent)
    }

    // MARK: - The verb

    @Test("Without consent it asks, in the Force Stop sheet's terms, and sends nothing")
    func asksEveryTime() async throws {
        let fixture = try await makeFixture(.forEveryone)
        let error = try await #require(throws: CommandError.self) {
            try await stopAnyway(fixture, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt == VMCommandCore.stopAnywayPrompt(fixture.instance))
        #expect(prompt.kind == .stopAnyway)
        #expect(prompt.title == "Stop \u{201C}Anyway\u{201D} Anyway?")
        #expect(
            prompt.message
                == "macOS shuts down without waiting for apps. Apps still open quit without asking to save.")
        #expect(prompt.confirmTitle == "Stop Anyway")
        #expect(prompt.confirmIsDestructive)
        #expect(prompt.dismissTitle == "Cancel")
        #expect(prompt.alternatives.isEmpty)
        #expect(fixture.probe.powerRequests.isEmpty)
    }

    // MARK: - Restart Anyway

    private func restartAnyway(_ fixture: Fixture, consent: Consent) async throws {
        try await fixture.harness.core.restart(
            .id(fixture.instance.id), disposition: .anyway, timeout: nil, consent: consent)
    }

    @Test("Restart Anyway asks every time, in Stop Anyway's terms reworded for a restart, and sends nothing")
    func restartAnywayAsksEveryTime() async throws {
        let fixture = try await makeFixture(.forEveryone)
        for consent in [Consent.none, Consent([.stopAnyway])] {
            let error = try await #require(throws: CommandError.self) {
                try await restartAnyway(fixture, consent: consent)
            }
            let prompt = try #require(error.confirmationPrompt)
            #expect(prompt == VMCommandCore.restartAnywayPrompt(fixture.instance))
            #expect(prompt.kind == .restartAnyway)
            #expect(prompt.title == "Restart \u{201C}Anyway\u{201D} Anyway?")
            #expect(
                prompt.message
                    == "macOS shuts down without waiting for apps. Apps still open quit without asking to save. "
                    + "Kernova then starts \u{201C}Anyway\u{201D} again.")
            #expect(prompt.confirmTitle == "Restart Anyway")
            #expect(prompt.confirmIsDestructive)
            #expect(prompt.dismissTitle == "Cancel")
        }
        #expect(fixture.probe.powerRequests.isEmpty)
        #expect(fixture.harness.virtualization.startCallCount == 0)
    }

    @Test(
        "Where no agent offers it, Restart Anyway is refused as Stop Anyway is, before any question and with nothing sent",
        arguments: Agents.allCases.filter { !$0.canStopAnyway })
    func restartAnywayRefusedWithoutTheSystemService(agents: Agents) async throws {
        let fixture = try await makeFixture(agents)
        for consent in [Consent.none, .all] {
            let error = try await #require(throws: CommandError.self) {
                try await restartAnyway(fixture, consent: consent)
            }
            let requirement = try #require(error.stepRequirement, "\(error)")
            #expect(
                requirement
                    == VMCommandCore.stopAnywayUnavailable(fixture.instance, verb: .restart))
            #expect(requirement.title == "Can\u{2019}t Restart Anyway")
            #expect(
                requirement.message
                    == VMCommandCore.stopAnywayUnavailable(fixture.instance, verb: .stop).message)
        }
        #expect(fixture.probe.powerRequests.isEmpty)
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.harness.virtualization.startCallCount == 0)
        #expect(fixture.instance.status == .running)
    }

    @Test("A system service that refuses Restart Anyway leaves the guest running, its boot withdrawn")
    func restartAnywayUntakenWithdrawsItsBoot() async throws {
        let fixture = try await makeFixture(.forEveryone) { _ in [.refused(WireError(.powerActionUnsupported))] }
        let error = try await #require(throws: CommandError.self) {
            try await restartAnyway(fixture, consent: .all)
        }
        #expect(error.stepRequirement?.title == "Can\u{2019}t Restart Anyway")
        #expect(!fixture.instance.activity.liveSessionContinues)
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.harness.virtualization.startCallCount == 0)
        #expect(fixture.instance.status == .running)
    }

    // MARK: - Doors

    @Test("Shortcuts' and AppleScript's stop methods each name the anyway disposition")
    func doorsNameTheDisposition() {
        #expect(VMStopMethod.anyway.disposition == .anyway)
        #expect(VMStopMethod(.anyway) == .anyway)
        #expect(Set(VMStopMethod.allCases.map(\.disposition)) == Set(StopDisposition.allCases))
        #expect(VMStopMethod.caseDisplayRepresentations[.anyway] != nil)
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
        #expect(declined.confirmationPrompt?.kind == .stopAnyway)
        #expect(fixture.probe.powerRequests.isEmpty)
        try await gateway.stop(fixture.instance.id, disposition: .anyway, consent: Consent([.stopAnyway]))
        #expect(fixture.probe.powerRequestsIgnoringApps.map(\.action) == [.shutdown])
    }
}
