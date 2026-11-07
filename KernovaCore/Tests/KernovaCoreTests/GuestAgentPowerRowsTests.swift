import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The Guest Agent Status panel's two power rows, read from a macOS guest's
/// hub as its agents connect and its power routings run.
@Suite("Guest agent power rows", .serialized, .caseScoped)
@MainActor
struct GuestAgentPowerRowsTests {
    private let preferences = makeTestPreferences()

    private struct Fixture {
        let harness: WiredCommandCore.Scripted<MockVirtualizationService>
        let instance: VMInstance
        let probe: AgentHubProbe
    }

    /// A running macOS VM with a session agent whose session is at the
    /// guest's screen (`.on`), in the background (`.off`) or absent (`nil`),
    /// and the system service when `system`. Each connects first the session
    /// agent, then the system service, and answers power requests only as the
    /// test delivers them.
    private func makeFixture(session: ConsoleState?, system: Bool) async throws -> Fixture {
        let harness = WiredCommandCore.Scripted<MockVirtualizationService>(
            WiredCommandCore(virtualization: MockVirtualizationService(), preferences: preferences))
        let probe = AgentHubProbe()
        let instance = harness.wired.register(
            name: "Panel", phase: .running(sessionID: UUID()), guestOS: .macOS, agentConnector: probe)
        instance.agentHub.attach(
            probe, policy: PolicySnapshot(), republisher: GuestLogRepublisher(vmLabel: instance.name))
        try await probe.changed.wait { probe.isStarted }
        var peers = 0
        if let session {
            #expect(
                probe.connectPowerPeer(
                    claim: PeerClaim(role: .sessionPeer, scope: .system, os: .macOS, architecture: .arm64),
                    state: PeerSessionState(console: session, sessionID: "2", userName: "pbear"),
                    offer: PowerOffer(actions: [.shutdown], asksAppsToQuit: true)) != nil)
            peers += 1
        }
        if system {
            #expect(
                probe.connectPowerPeer(
                    claim: PeerClaim(role: .systemPeer, scope: .system, os: .macOS, architecture: .arm64),
                    state: PeerSessionState(console: session ?? .off, consoleSessionID: session == .on ? "2" : ""),
                    offer: PowerOffer(actions: [], ignoringApps: [.shutdown])) != nil)
            peers += 1
        }
        try await waitForChange { instance.agentHubSnapshot.peers.count == peers }
        return Fixture(harness: harness, instance: instance, probe: probe)
    }

    /// The Stop and Restart row, then the Stop Anyway and Restart Anyway row.
    private static func powerRows(_ instance: VMInstance) -> [GuestAgentPresentation.CapabilityRow] {
        GuestAgentPresentation(hub: instance.agentHubSnapshot).capabilities.filter {
            ["Stop and Restart", "Stop Anyway and Restart Anyway"].contains($0.title)
        }
    }

    nonisolated private static let notOnScreen = "Available to the session at the guest\u{2019}s screen."
    nonisolated private static let throughSession = "Through the session agent"
    nonisolated private static let throughSystem = "Through the system service"
    nonisolated private static let noSystemService = "No system service is connected."

    /// Which agents are connected — the session agent's console state, or
    /// `nil` for none, and whether the system service is — and each row's
    /// availability and detail.
    nonisolated static let agentCases: [(ConsoleState?, Bool, Bool, String, Bool, String)] = [
        (nil, false, false, "No Kernova agent is connected.", false, noSystemService),
        (.on, false, true, throughSession, false, noSystemService),
        (.off, false, false, notOnScreen, false, noSystemService),
        (nil, true, false, notOnScreen, true, throughSystem),
        (.off, true, false, notOnScreen, true, throughSystem),
        (.on, true, true, throughSession, true, throughSystem),
    ]

    @Test(
        "Each power row names the agent its commands would ask, or why none would",
        arguments: agentCases)
    func rowsFollowTheAgents(
        session: ConsoleState?, system: Bool, stopAvailable: Bool, stop: String, anywayAvailable: Bool,
        anyway: String
    ) async throws {
        let fixture = try await makeFixture(session: session, system: system)
        #expect(
            Self.powerRows(fixture.instance) == [
                .init(title: "Stop and Restart", isAvailable: stopAvailable, detail: stop),
                .init(title: "Stop Anyway and Restart Anyway", isAvailable: anywayAvailable, detail: anyway),
            ])
    }

    @Test("A running Stop shows its stage on the Stop and Restart row alone")
    func gracefulRoutingShowsOnItsRow() async throws {
        let fixture = try await makeFixture(session: .on, system: true)
        let stop = Task { @MainActor in
            try await fixture.harness.core.stop(.id(fixture.instance.id), disposition: .graceful, consent: .none)
        }
        try await waitForChange { fixture.instance.agentHubSnapshot.routing?.stage == .asking }
        let anyway = GuestAgentPresentation.CapabilityRow(
            title: "Stop Anyway and Restart Anyway", isAvailable: true, detail: Self.throughSystem)
        #expect(
            Self.powerRows(fixture.instance) == [
                .init(title: "Stop and Restart", isAvailable: true, detail: "Shutting down\u{2026}"), anyway,
            ])

        let id = try #require(fixture.probe.powerRequests.first?.id)
        fixture.probe.deliver(.power(id, .accepted), fromConnection: 0)
        fixture.probe.deliver(
            .power(id, .progress(.waitingOnApps, [AppValue(displayName: "TextEdit")])), fromConnection: 0)
        try await waitForChange {
            fixture.instance.agentHubSnapshot.routing?.stage == .waitingOnApps([AppValue(displayName: "TextEdit")])
        }
        #expect(
            Self.powerRows(fixture.instance) == [
                .init(title: "Stop and Restart", isAvailable: true, detail: "Waiting on TextEdit"), anyway,
            ])

        fixture.probe.deliver(.power(id, .finished(.handedOff)), fromConnection: 0)
        try await stop.value
    }

    @Test("A running Stop Anyway shows its stage on the Stop Anyway and Restart Anyway row alone")
    func ignoringAppsRoutingShowsOnItsRow() async throws {
        let fixture = try await makeFixture(session: .on, system: true)
        let stop = Task { @MainActor in
            try await fixture.harness.core.stop(
                .id(fixture.instance.id), disposition: .anyway, consent: Consent([.stopAnyway]))
        }
        try await waitForChange { fixture.instance.agentHubSnapshot.routing?.stage == .asking }
        #expect(
            Self.powerRows(fixture.instance) == [
                .init(title: "Stop and Restart", isAvailable: true, detail: Self.throughSession),
                .init(title: "Stop Anyway and Restart Anyway", isAvailable: true, detail: "Shutting down\u{2026}"),
            ])

        let id = try #require(fixture.probe.powerRequestsIgnoringApps.first?.id)
        fixture.probe.deliver(.power(id, .accepted), fromConnection: 1)
        fixture.probe.deliver(.power(id, .finished(.handedOff)), fromConnection: 1)
        try await stop.value
    }
}
