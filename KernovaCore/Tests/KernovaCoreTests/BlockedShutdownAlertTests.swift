import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What the GUI's Stop and Restart show when apps in the guest block the
/// shutdown: the Shut Down Anyway question where an agent can shut down past
/// them, and the blocked alert, naming Force Stop, where none can.
@Suite("Blocked shutdown alert", .serialized, .caseScoped)
@MainActor
struct BlockedShutdownAlertTests {
    private let presenter = MockVMLibraryPresenting()
    private let preferences = makeTestPreferences()
    nonisolated private static let blocked: [PowerRequestResult] = [
        .accepted, .finished(.blocked([AppValue(displayName: "Text Editor", identifier: "org.gnome.TextEditor")])),
    ]

    private struct Fixture {
        let viewModel: VMLibraryViewModel
        let instance: VMInstance
        let probe: AgentHubProbe
    }

    /// A running Linux VM whose console session's peer reports every
    /// shutdown blocked, beside a system peer offering to shut down past the
    /// apps blocking it when `skippable`.
    private func makeFixture(skippable: Bool) async throws -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        viewModel.presenter = presenter
        let probe = AgentHubProbe()
        let instance = viewModel.library.registerFixture(
            name: "Routed", phase: .running(sessionID: UUID()), agentConnector: probe)
        instance.agentHub.attach(
            probe, policy: PolicySnapshot(), republisher: GuestLogRepublisher(vmLabel: instance.name))
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connectPowerPeer { _ in Self.blocked } != nil)
        if skippable {
            #expect(
                probe.connectPowerPeer(
                    claim: PeerClaim(role: .systemPeer, scope: .system, os: .linux, architecture: .arm64),
                    state: PeerSessionState(
                        console: .on, consoleSessionID: AgentHubProbe.consoleSessionPeer.state.sessionID),
                    offer: PowerOffer(
                        actions: [], skippingBlockers: [.shutdown, .restart], actionsAbsence: .unsavedWorkUnseen),
                    answering: { _ in [.accepted, .finished(.handedOff)] }) != nil)
        }
        try await waitForChange {
            instance.agentHubSnapshot.power == .agent(.sessionPeer)
                && instance.agentHubSnapshot.peers.count == (skippable ? 2 : 1)
        }
        return Fixture(viewModel: viewModel, instance: instance, probe: probe)
    }

    @Test("Stop asks Shut Down Anyway, and confirming it shuts down past the apps blocking it")
    func stopAsksAndSkips() async throws {
        let fixture = try await makeFixture(skippable: true)
        presenter.confirmationAnswer = .answered(true)

        await fixture.viewModel.stop(fixture.instance)

        let prompt = try #require(presenter.confirmationRequests.first?.prompt)
        #expect(presenter.confirmationRequests.count == 1)
        #expect(prompt.title == "\u{201C}Routed\u{201D} Didn\u{2019}t Shut Down")
        #expect(prompt.confirmTitle == "Shut Down Anyway")
        #expect(prompt.dismissTitle == "Cancel")
        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false, false, true])
        #expect(presenter.errors.isEmpty)
    }

    @Test("Declining Shut Down Anyway asks nothing more of the guest and shows no error")
    func stopDeclined() async throws {
        let fixture = try await makeFixture(skippable: true)
        presenter.confirmationAnswer = .answered(false)

        await fixture.viewModel.stop(fixture.instance)

        #expect(presenter.confirmationRequests.count == 1)
        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false])
        #expect(presenter.errors.isEmpty)
    }

    @Test("Where no agent can shut down past them, Stop shows the blocked alert naming Force Stop, with no question")
    func stopWithoutSkip() async throws {
        let fixture = try await makeFixture(skippable: false)

        await fixture.viewModel.stop(fixture.instance)

        #expect(presenter.confirmationRequests.isEmpty)
        #expect(presenter.errorTitles == ["\u{201C}Routed\u{201D} Didn\u{2019}t Shut Down"])
        #expect(
            presenter.errors == [
                "Text Editor is blocking it. To shut it down anyway, use Force Stop, which loses any unsaved data "
                    + "inside the guest."
            ])
    }

    @Test("Restart asks Restart Anyway; confirming it shuts down past the apps and owes the boot")
    func restartAsks() async throws {
        let fixture = try await makeFixture(skippable: true)
        presenter.confirmationAnswer = .answered(true)

        let restart = Task { @MainActor in await fixture.viewModel.restart(fixture.instance) }
        try await fixture.probe.changed.wait { fixture.probe.powerRequests.count == 3 }
        try await waitForChange {
            !fixture.instance.activity.isRequestingStop && fixture.instance.activity.liveSessionContinues
        }
        let session = try #require(fixture.instance.activity.liveSessionID)
        fixture.instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        await restart.value

        let prompt = try #require(presenter.confirmationRequests.first?.prompt)
        #expect(prompt.title == "\u{201C}Routed\u{201D} Didn\u{2019}t Restart")
        #expect(prompt.confirmTitle == "Restart Anyway")
        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false, false, true])
        #expect(fixture.instance.status == .running)
        #expect(fixture.instance.activity.liveSessionID != session)
        #expect(presenter.errors.isEmpty)
    }
}
