import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Stop and Restart sent through the VM's agent hub: the guest's agents first,
/// the ACPI button when none takes the request.
@Suite("Guest shutdown routing", .serialized, .caseScoped)
@MainActor
struct GuestShutdownRoutingTests {
    private let preferences = makeTestPreferences()
    nonisolated private static let blocking = [
        AppValue(displayName: "Text Editor", identifier: "org.gnome.TextEditor"),
        AppValue(displayName: "Terminal", identifier: "org.gnome.Terminal"),
    ]

    private struct Fixture {
        let harness: WiredCommandCore.Scripted<MockVirtualizationService>
        let instance: VMInstance
        let session: UUID
        let probe: AgentHubProbe
    }

    /// A running Linux VM whose hub's connections `probe` stands in for, with a
    /// console session's peer answering each power request with `answering`'s
    /// results — or, without `answering`, waiting for the test to answer — and
    /// none at all when `peer` is false.
    private func makeFixture(
        peer: Bool = true, answering: (@Sendable (PowerAction) -> [PowerRequestResult])? = nil
    ) async throws -> Fixture {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore.Scripted<MockVirtualizationService>(
            WiredCommandCore(virtualization: virtualization, preferences: preferences))
        let probe = AgentHubProbe()
        let session = UUID()
        let instance = harness.wired.register(
            name: "Routed", phase: .running(sessionID: session), agentConnector: probe)
        instance.agentHub.attach(
            probe, policy: PolicySnapshot(), republisher: GuestLogRepublisher(vmLabel: instance.name))
        try await probe.changed.wait { probe.isStarted }
        if peer {
            #expect(probe.connectPowerPeer(answering: answering) != nil)
            try await waitForChange { instance.agentHubSnapshot.power == .agent(.sessionPeer) }
        }
        return Fixture(harness: harness, instance: instance, session: session, probe: probe)
    }

    private func stop(_ fixture: Fixture) async throws {
        try await fixture.harness.core.stop(.id(fixture.instance.id), disposition: .graceful, consent: .none)
    }

    // MARK: - Which way the request goes

    @Test("With no agent to take it, Stop presses the ACPI button")
    func noAgentPressesACPI() async throws {
        let fixture = try await makeFixture(peer: false)
        try await stop(fixture)
        #expect(fixture.harness.virtualization.stopCallCount == 1)
        #expect(fixture.instance.status == .stopped)
    }

    @Test("An agent's refusal falls through to the ACPI button")
    func refusalPressesACPI() async throws {
        let fixture = try await makeFixture { _ in [.refused(WireError(.powerNotPermitted))] }
        try await stop(fixture)
        #expect(fixture.probe.powerRequests.map(\.action) == [.shutdown])
        #expect(fixture.harness.virtualization.stopCallCount == 1)
    }

    /// Every outcome of a request an agent took: none of them presses the
    /// ACPI button, and what failed throws.
    nonisolated static let takenOutcomes: [(results: [PowerRequestResult], throwsError: Bool)] = [
        ([.accepted, .finished(.handedOff)], false),
        ([.accepted, .lostAfterAcceptance], false),
        ([.accepted, .finished(.blocked(blocking))], true),
        ([.accepted, .finished(.cancelledInGuest)], true),
        ([.accepted, .finished(.failed(WireError(.powerOsFailed, posixErrno: EPERM)))], true),
        ([.accepted, .indeterminate], true),
    ]

    @Test("An outcome an agent took never presses the ACPI button", arguments: takenOutcomes.indices)
    func takenOutcomeSkipsACPI(row: Int) async throws {
        let (results, throwsError) = Self.takenOutcomes[row]
        let fixture = try await makeFixture { _ in results }

        if throwsError {
            let error = try await #require(throws: CommandError.self) { try await stop(fixture) }
            guard case .shutdownNotCarriedOut(let failure) = error else {
                Issue.record("Expected the shutdown not carried out, got \(error)")
                return
            }
            #expect(failure.session == fixture.session)
            guard case .operationFailed(.stop, _, _, nil) = error.dto else {
                Issue.record("Expected the wire to read a stop that failed, got \(error.dto)")
                return
            }
        } else {
            try await stop(fixture)
        }
        #expect(fixture.probe.powerRequests.map(\.action) == [.shutdown])
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.instance.status == .running)
    }

    @Test(
        "A Stop the ACPI button took is over once pressed: the guest still running, Stop, Restart and Force Stop are offered and a second Stop presses it again"
    )
    func acpiPressLeavesTheVMStoppable() async throws {
        let fixture = try await makeFixture(peer: false)
        fixture.harness.virtualization.guestIgnoresShutdownRequest = true
        let capabilities = fixture.harness.library.capabilities

        try await stop(fixture)
        #expect(fixture.instance.status == .running)
        #expect(!fixture.instance.activity.isRequestingStop)
        #expect(fixture.instance.agentHubSnapshot.routing == nil)
        for capability in [VMCapability.stop, .restart, .forceStop] {
            #expect(capabilities.isAvailable(capability, on: fixture.instance), "\(capability)")
        }

        try await stop(fixture)
        #expect(fixture.harness.virtualization.stopCallCount == 2)
    }

    // MARK: - Restart

    @Test(
        "A Restart handed to an agent registers its boot through the Restart's request and boots once the guest is off")
    func restartThroughAgent() async throws {
        let fixture = try await makeFixture { _ in [.accepted, .finished(.handedOff)] }
        let restart = Task { @MainActor in
            try await fixture.harness.core.restart(.id(fixture.instance.id), timeout: nil, consent: .none)
        }
        try await fixture.probe.changed.wait { fixture.probe.powerRequests.count == 1 }
        try await waitForChange {
            !fixture.instance.activity.isRequestingStop && fixture.instance.activity.liveSessionContinues
        }

        fixture.instance.activity.deliverSessionEvent(.guestDidStop, from: fixture.session)
        try await restart.value

        #expect(fixture.probe.powerRequests.map(\.action) == [.shutdown])
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.harness.virtualization.startCallCount == 1)
        #expect(fixture.instance.status == .running)
    }

    @Test("A Restart with no agent to take it takes the same request through the ACPI button")
    func restartThroughACPI() async throws {
        let fixture = try await makeFixture(peer: false)
        try await fixture.harness.core.restart(.id(fixture.instance.id), timeout: nil, consent: .none)
        #expect(fixture.probe.powerRequests.isEmpty)
        #expect(fixture.harness.virtualization.stopCallCount == 1)
        #expect(fixture.harness.virtualization.startCallCount == 1)
        #expect(fixture.instance.status == .running)
    }

    @Test("A Restart an agent's apps blocked withdraws its boot and says why")
    func blockedRestartWithdrawsItsBoot() async throws {
        let fixture = try await makeFixture { _ in [.accepted, .finished(.blocked(Self.blocking))] }
        let error = try await #require(throws: CommandError.self) {
            try await fixture.harness.core.restart(.id(fixture.instance.id), timeout: nil, consent: .none)
        }
        #expect(error.alertTitle == "\u{201C}Routed\u{201D} Didn\u{2019}t Shut Down")
        #expect(!fixture.instance.activity.liveSessionContinues)
        #expect(fixture.probe.powerRequests.map(\.action) == [.shutdown])
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.instance.status == .running)
    }

    @Test("A Stop routed through an agent while a Restart waits cancels the Restart")
    func stopWithdrawsAWaitingRestart() async throws {
        let fixture = try await makeFixture { _ in [.accepted, .finished(.handedOff)] }
        let restart = Task { @MainActor in
            try await fixture.harness.core.restart(.id(fixture.instance.id), timeout: nil, consent: .none)
        }
        try await fixture.probe.changed.wait { fixture.probe.powerRequests.count == 1 }
        try await waitForChange {
            !fixture.instance.activity.isRequestingStop && fixture.instance.activity.liveSessionContinues
        }

        try await stop(fixture)
        #expect(!fixture.instance.activity.liveSessionContinues)
        #expect(fixture.probe.powerRequests.map(\.action) == [.shutdown, .shutdown])

        fixture.instance.activity.deliverSessionEvent(.guestDidStop, from: fixture.session)
        let error = try await #require(throws: CommandError.self) { try await restart.value }
        #expect(error.message.contains("was stopped while it restarted"))
        #expect(fixture.harness.virtualization.startCallCount == 0)
        #expect(fixture.instance.status == .stopped)
    }

    // MARK: - At the login window

    /// A running macOS VM at its login window: a background session's peer,
    /// and the system service reporting the console off and saying macOS
    /// ignores the power button there, offering Shut Down Anyway when
    /// `anyway`.
    private func makeLoginWindowFixture(anyway: Bool) async throws -> Fixture {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore.Scripted<MockVirtualizationService>(
            WiredCommandCore(virtualization: virtualization, preferences: preferences))
        let probe = AgentHubProbe()
        let session = UUID()
        let instance = harness.wired.register(
            name: "Routed", phase: .running(sessionID: session), guestOS: .macOS, agentConnector: probe)
        instance.agentHub.attach(
            probe, policy: PolicySnapshot(), republisher: GuestLogRepublisher(vmLabel: instance.name))
        try await probe.changed.wait { probe.isStarted }
        let handsOff: @Sendable (PowerAction) -> [PowerRequestResult] = { _ in [.accepted, .finished(.handedOff)] }
        #expect(
            probe.connectPowerPeer(
                claim: PeerClaim(role: .sessionPeer, scope: .system, os: .macOS, architecture: .arm64),
                state: PeerSessionState(console: .off, sessionID: "2", userName: "pbear"),
                offer: PowerOffer(actions: [.shutdown, .restart], asksAppsToQuit: true), answering: handsOff)
                != nil)
        #expect(
            probe.connectPowerPeer(
                claim: PeerClaim(role: .systemPeer, scope: .system, os: .macOS, architecture: .arm64),
                state: PeerSessionState(console: .off),
                offer: PowerOffer(actions: [], ignoringApps: anyway ? [.shutdown] : [], powerButtonIgnored: true),
                answering: handsOff) != nil)
        try await waitForChange {
            instance.agentHubSnapshot.peers.count == 2
                && instance.agentHubSnapshot.shutsDownIgnoringApps == anyway
                && instance.agentHubSnapshot.features[.power].isAvailable
        }
        return Fixture(harness: harness, instance: instance, session: session, probe: probe)
    }

    nonisolated static let loginWindow =
        "\u{201C}Routed\u{201D} is at its login window, where macOS doesn\u{2019}t act on a shutdown request."

    /// The ways out the login window's refusal names, by whether the guest offers Shut Down Anyway.
    nonisolated static func ways(anyway: Bool) -> String {
        anyway ? "Shut Down Anyway\u{2026} or Force Stop\u{2026}" : "Force Stop\u{2026}"
    }

    @Test(
        "At the login window, Stop sends nothing and refuses as a step naming Shut Down Anyway… exactly when the guest offers it",
        arguments: [true, false])
    func stopAtLoginWindow(anyway: Bool) async throws {
        let fixture = try await makeLoginWindowFixture(anyway: anyway)
        let error = try await #require(throws: CommandError.self) { try await stop(fixture) }
        guard case .stepRequired(let step) = error else {
            Issue.record("Expected a step refusal, got \(error)")
            return
        }
        #expect(step.title == "Can\u{2019}t Shut Down \u{201C}Routed\u{201D}")
        #expect(step.message == Self.loginWindow + " Use \(Self.ways(anyway: anyway)) to stop it.")
        #expect(step.routes.isEmpty)
        #expect(fixture.probe.powerRequests.isEmpty)
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.instance.status == .running)
        #expect(!fixture.instance.activity.isRequestingStop)
    }

    @Test("At the login window, Restart sends nothing, boots nothing, and refuses as a step", arguments: [true, false])
    func restartAtLoginWindow(anyway: Bool) async throws {
        let fixture = try await makeLoginWindowFixture(anyway: anyway)
        let error = try await #require(throws: CommandError.self) {
            try await fixture.harness.core.restart(.id(fixture.instance.id), timeout: nil, consent: .none)
        }
        guard case .stepRequired(let step) = error else {
            Issue.record("Expected a step refusal, got \(error)")
            return
        }
        #expect(step.title == "Can\u{2019}t Restart \u{201C}Routed\u{201D}")
        #expect(
            step.message == Self.loginWindow + " Use \(Self.ways(anyway: anyway)) to stop it, then start it again.")
        #expect(!fixture.instance.activity.liveSessionContinues)
        #expect(fixture.probe.powerRequests.isEmpty)
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.harness.virtualization.startCallCount == 0)
        #expect(fixture.instance.status == .running)
    }

    @Test("At the login window, Shut Down Anyway goes to the system service")
    func shutDownAnywayAtLoginWindow() async throws {
        let fixture = try await makeLoginWindowFixture(anyway: true)
        _ = try await #require(throws: CommandError.self) { try await stop(fixture) }
        try await fixture.harness.core.stop(
            .id(fixture.instance.id), disposition: .anyway, consent: Consent([.shutDownAnyway]))
        #expect(fixture.probe.powerRequestsIgnoringApps.map(\.action) == [.shutdown])
        #expect(fixture.probe.powerRequests.count == 1)
        #expect(fixture.harness.virtualization.stopCallCount == 0)
    }

    // MARK: - While the request is in flight

    @Test("While a stop request is in flight, Stop and Restart are shown dimmed and Force Stop stays available")
    func inFlightGate() async throws {
        let fixture = try await makeFixture()
        let capabilities = fixture.harness.library.capabilities
        let first = Task { @MainActor in try await stop(fixture) }
        try await fixture.probe.changed.wait { fixture.probe.powerRequests.count == 1 }
        #expect(fixture.instance.activity.isRequestingStop)

        for capability in [VMCapability.stop, .restart] {
            #expect(capabilities.isApplicable(capability, to: fixture.instance), "\(capability)")
            #expect(!capabilities.isAvailable(capability, on: fixture.instance), "\(capability)")
        }
        #expect(capabilities.isAvailable(.forceStop, on: fixture.instance))
        let second = try await #require(throws: CommandError.self) { try await stop(fixture) }
        #expect(second.isBusy)
        #expect(
            second.message
                == "\u{201C}Routed\u{201D} is busy asking its guest to shut down. Wait for it to finish, then try again."
        )
        #expect(fixture.probe.powerRequests.count == 1)

        let id = try #require(fixture.probe.powerRequests.first?.id)
        fixture.probe.deliver(.power(id, .accepted), fromConnection: 0)
        fixture.probe.deliver(.power(id, .finished(.handedOff)), fromConnection: 0)
        try await first.value
        #expect(!fixture.instance.activity.isRequestingStop)
        #expect(capabilities.isAvailable(.stop, on: fixture.instance))
    }

    // MARK: - Copy

    private static func copy(
        _ reason: GuestShutdownNotCarriedOut.Reason, anyway: Bool = false
    ) -> (title: String?, message: String?) {
        let error = GuestShutdownNotCarriedOut(
            vmName: "Fedora", session: UUID(), reason: reason, offersShutDownAnyway: anyway)
        return (error.alertTitle, error.errorDescription)
    }

    @Test("Apps blocking the shutdown are named, and Force Stop… is how to shut it down anyway")
    func blockedCopy() {
        let forceStop =
            " To shut it down anyway, use Force Stop\u{2026}, which loses any unsaved data inside the guest."
        let one = Self.copy(.blocked([AppValue(displayName: "Text Editor")]))
        #expect(one.title == "\u{201C}Fedora\u{201D} Didn\u{2019}t Shut Down")
        #expect(one.message == "Text Editor is blocking it." + forceStop)
        #expect(Self.copy(.blocked(Self.blocking)).message == "Text Editor and Terminal are blocking it." + forceStop)
        let three = Self.blocking + [AppValue(displayName: "", identifier: "firefox")]
        #expect(Self.copy(.blocked(three)).message == "Text Editor, Terminal, and firefox are blocking it." + forceStop)
        #expect(Self.copy(.blocked([])).message == "An app is blocking it." + forceStop)
    }

    @Test("Where the guest offers Shut Down Anyway…, the blocked and can't-tell alerts name it beside Force Stop…")
    func shutDownAnywayCopy() {
        #expect(
            Self.copy(.blocked([AppValue(displayName: "Text Editor")]), anyway: true).message
                == "Text Editor is blocking it. Use Shut Down Anyway\u{2026} to shut it down without waiting for apps, "
                + "or Force Stop\u{2026}, which loses any unsaved data inside the guest.")
        #expect(
            Self.copy(.indeterminate, anyway: true).message
                == "Kernova can\u{2019}t tell whether \u{201C}Fedora\u{201D} is shutting down. "
                + "Use Shut Down Anyway\u{2026} or Force Stop\u{2026} if it doesn\u{2019}t stop.")
    }

    @Test("A cancel inside the guest, an OS failure, and an outcome Kernova can't tell each read as what is known")
    func otherOutcomeCopy() {
        #expect(Self.copy(.cancelledInGuest).message == "Shutting down was cancelled inside \u{201C}Fedora\u{201D}.")
        #expect(
            Self.copy(.failed(WireError(.powerOsFailed, posixErrno: EPERM))).message
                == "\u{201C}Fedora\u{201D} couldn\u{2019}t shut down: Operation not permitted.")
        #expect(
            Self.copy(.failed(WireError(.powerOsFailed))).message == "\u{201C}Fedora\u{201D} couldn\u{2019}t shut down."
        )
        let indeterminate = Self.copy(.indeterminate)
        #expect(indeterminate.title == nil)
        #expect(
            indeterminate.message
                == "Kernova can\u{2019}t tell whether \u{201C}Fedora\u{201D} is shutting down. Use Force Stop\u{2026} if it doesn\u{2019}t stop."
        )
    }
}
