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
    /// none at all when `peer` is false. With `skipping`, a system peer too,
    /// offering only to shut down past blocking apps, as a Linux system
    /// service does while a desktop session runs, and answering with
    /// `skipping`'s results.
    private func makeFixture(
        peer: Bool = true, answering: (@Sendable (AgentHubProbe.PowerRequest) -> [PowerRequestResult])? = nil,
        skipping: (@Sendable (AgentHubProbe.PowerRequest) -> [PowerRequestResult])? = nil
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
        if let skipping {
            #expect(
                probe.connectPowerPeer(
                    claim: PeerClaim(role: .systemPeer, scope: .system, os: .linux, architecture: .arm64),
                    state: PeerSessionState(
                        console: .on, consoleSessionID: AgentHubProbe.consoleSessionPeer.state.sessionID),
                    offer: Self.skipOnly, answering: skipping) != nil)
            try await waitForChange { instance.agentHubSnapshot.peers.count == 2 }
        }
        return Fixture(harness: harness, instance: instance, session: session, probe: probe)
    }

    private func stop(_ fixture: Fixture, consent: Consent = .none) async throws {
        try await fixture.harness.core.stop(.id(fixture.instance.id), disposition: .graceful, consent: consent)
    }

    /// A Linux system service's offer while a desktop session runs.
    nonisolated private static let skipOnly = PowerOffer(
        actions: [], skippingBlockers: [.shutdown, .restart], actionsAbsence: .unsavedWorkUnseen)
    nonisolated private static let blockedOutcome: [PowerRequestResult] = [.accepted, .finished(.blocked(blocking))]
    nonisolated private static let handedOff: [PowerRequestResult] = [.accepted, .finished(.handedOff)]
    private static let skipConsent = Consent([.skipBlockingApps])

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
            await #expect(throws: CommandError.self) { try await stop(fixture) }
        } else {
            try await stop(fixture)
        }
        #expect(fixture.probe.powerRequests.map(\.action) == [.shutdown])
        #expect(fixture.harness.virtualization.stopCallCount == 0)
        #expect(fixture.instance.status == .running)
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

    // MARK: - Past the apps blocking it

    @Test("A Stop apps block, where an agent can shut down past them, asks first, and asks nothing of that agent")
    func blockedStopAsks() async throws {
        let fixture = try await makeFixture(answering: { _ in Self.blockedOutcome }, skipping: { _ in Self.handedOff })
        let error = try await #require(throws: CommandError.self) { try await stop(fixture) }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .skipBlockingApps)
        #expect(prompt.title == "\u{201C}Routed\u{201D} Didn\u{2019}t Shut Down")
        #expect(
            prompt.message
                == "Text Editor and Terminal are blocking it. If you shut it down anyway, the guest\u{2019}s services "
                + "stop and its disks unmount as in any shutdown, but the apps blocking it close without being asked "
                + "to save.")
        #expect(prompt.confirmTitle == "Shut Down Anyway")
        #expect(prompt.confirmIsDestructive)
        #expect(prompt.dismissTitle == "Cancel")
        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false])
        #expect(fixture.instance.status == .running)
    }

    @Test("Where no agent can shut down past them, a blocked Stop names Force Stop and asks nothing")
    func blockedStopWithoutSkip() async throws {
        let fixture = try await makeFixture { _ in Self.blockedOutcome }
        let error = try await #require(throws: CommandError.self) { try await stop(fixture) }
        #expect(error.confirmationPrompt == nil)
        #expect(
            error.message.hasSuffix(
                "To shut it down anyway, use Force Stop, which loses any unsaved data inside the guest."))
    }

    @Test("With the consent, a blocked Stop asks the agent that offers it to shut down past them")
    func consentedStopSkips() async throws {
        let fixture = try await makeFixture(answering: { _ in Self.blockedOutcome }, skipping: { _ in Self.handedOff })
        try await stop(fixture, consent: Self.skipConsent)
        #expect(
            fixture.probe.powerRequests.map { [$0.action == .shutdown, $0.skippingBlockers] } == [
                [true, false], [true, true],
            ])
        #expect(fixture.harness.virtualization.stopCallCount == 0)
    }

    @Test("With the consent, a Stop no app blocks shuts down as any Stop does, asking nothing more")
    func consentedStopUnblocked() async throws {
        let fixture = try await makeFixture(answering: { _ in Self.handedOff }, skipping: { _ in Self.handedOff })
        try await stop(fixture, consent: Self.skipConsent)
        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false])
    }

    @Test("A skip the agent refuses leaves the block standing, naming Force Stop, and presses no ACPI button")
    func refusedSkip() async throws {
        let fixture = try await makeFixture(
            answering: { _ in Self.blockedOutcome }, skipping: { _ in [.refused(WireError(.powerNotPermitted))] })
        let error = try await #require(throws: CommandError.self) {
            try await stop(fixture, consent: Self.skipConsent)
        }
        #expect(error.confirmationPrompt == nil)
        #expect(
            error.message.hasPrefix("Text Editor and Terminal are blocking it. To shut it down anyway, use Force Stop"))
        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false, true])
        #expect(fixture.harness.virtualization.stopCallCount == 0)
    }

    @Test("A Restart apps block asks in a Restart's words; with the consent it shuts down past them and boots")
    func blockedRestart() async throws {
        let fixture = try await makeFixture(answering: { _ in Self.blockedOutcome }, skipping: { _ in Self.handedOff })
        let error = try await #require(throws: CommandError.self) {
            try await fixture.harness.core.restart(.id(fixture.instance.id), timeout: nil, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .skipBlockingApps)
        #expect(prompt.title == "\u{201C}Routed\u{201D} Didn\u{2019}t Restart")
        #expect(
            prompt.message
                == "Text Editor and Terminal are blocking it. If you restart it anyway, the guest\u{2019}s services "
                + "stop and its disks unmount as in any restart, but the apps blocking it close without being asked "
                + "to save.")
        #expect(prompt.confirmTitle == "Restart Anyway")
        #expect(!fixture.instance.activity.liveSessionContinues)

        let restart = Task { @MainActor in
            try await fixture.harness.core.restart(.id(fixture.instance.id), timeout: nil, consent: Self.skipConsent)
        }
        try await fixture.probe.changed.wait { fixture.probe.powerRequests.count == 3 }
        try await waitForChange {
            !fixture.instance.activity.isRequestingStop && fixture.instance.activity.liveSessionContinues
        }
        fixture.instance.activity.deliverSessionEvent(.guestDidStop, from: fixture.session)
        try await restart.value

        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false, false, true])
        #expect(fixture.harness.virtualization.startCallCount == 1)
        #expect(fixture.instance.status == .running)
    }

    @Test("A door that asks through the consent policy answers the question and runs the Stop again, skipping them")
    func consentPolicyAnswers() async throws {
        let fixture = try await makeFixture(answering: { _ in Self.blockedOutcome }, skipping: { _ in Self.handedOff })
        var asked: [ConfirmationKind] = []
        try await VMConsentPolicy.run(prompting: { asked.append($0.kind) }) { consent in
            try await stop(fixture, consent: consent)
        }
        #expect(asked == [.skipBlockingApps])
        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false, false, true])
    }

    // MARK: - Restart All

    /// The routed VM and a stopped one, in a folder in that order.
    private func makeFolder(_ fixture: Fixture) throws -> (folder: VMGroupReference, idle: VMInstance) {
        let idle = fixture.harness.wired.register(name: "Idle")
        let folder = try fixture.harness.library.organization.createFolder(
            named: "Lab", members: [fixture.instance.id, idle.id])
        return (VMGroupReference(.folder, named: folder.id.uuidString), idle)
    }

    @Test("Restart All restarts the running VM through the single-VM restart and skips the stopped one")
    func restartAllRestartsTheRunningVM() async throws {
        let fixture = try await makeFixture(peer: false)
        let (folder, idle) = try makeFolder(fixture)

        let report = try await fixture.harness.core.groupAction(.restart, on: folder)

        #expect(report.results.map(\.outcome) == [.done(verb: .restart), .passedOver(reason: .state)])
        #expect(report.results.map { $0.line(for: .restart) } == ["Restarted Routed", "Skipped Idle: it is stopped."])
        #expect(report.undone.isEmpty)
        #expect(fixture.harness.virtualization.stopCallCount == 1)
        #expect(fixture.harness.virtualization.startCallCount == 1)
        #expect(fixture.instance.status == .running)
        #expect(fixture.instance.activity.liveSessionID != fixture.session)
        #expect(idle.status == .stopped)
    }

    @Test("Restart All restarts every running VM at once: a guest that holds its shutdown holds back only the report")
    func restartAllDoesNotWaitOnAStuckGuest() async throws {
        // The routed guest's agent takes the shutdown and its session never
        // ends until the test ends it.
        let fixture = try await makeFixture { _ in [.accepted, .finished(.handedOff)] }
        let otherSession = UUID()
        let other = fixture.harness.wired.register(name: "Other", phase: .running(sessionID: otherSession))
        let folder = try fixture.harness.library.organization.createFolder(
            named: "Lab", members: [fixture.instance.id, other.id])
        let reported = ReportBox()

        let restartAll = Task { @MainActor in
            reported.report = try await fixture.harness.core.groupAction(
                .restart, on: VMGroupReference(.folder, named: folder.id.uuidString))
        }
        try await waitForChange {
            other.status == .running && other.activity.liveSessionID.map { $0 != otherSession } == true
        }
        #expect(fixture.instance.activity.liveSessionID == fixture.session)
        #expect(reported.report == nil)

        fixture.instance.activity.deliverSessionEvent(.guestDidStop, from: fixture.session)
        try await restartAll.value

        let report = try #require(reported.report)
        #expect(report.results.map(\.vm.name) == ["Routed", "Other"])
        #expect(report.results.map(\.outcome) == [.done(verb: .restart), .done(verb: .restart)])
        #expect(fixture.instance.status == .running)
        #expect(fixture.harness.virtualization.startCallCount == 2)
    }

    /// Where a test reads a group action's report once it has come back.
    @MainActor
    private final class ReportBox {
        var report: VMGroupActionReport?
    }

    @Test("Restart All asks nothing of a guest whose blocking apps an agent could skip: it reports the question")
    func restartAllPassesTheQuestion() async throws {
        let fixture = try await makeFixture(answering: { _ in Self.blockedOutcome }, skipping: { _ in Self.handedOff })
        let (folder, _) = try makeFolder(fixture)

        let report = try await fixture.harness.core.groupAction(.restart, on: folder)

        guard case .needsAnswer(.restart, .confirmationRequired(let prompt)) = report.results.first?.outcome else {
            Issue.record("not the question: \(String(describing: report.results.first?.outcome))")
            return
        }
        #expect(prompt.kind == .skipBlockingApps)
        #expect(fixture.probe.powerRequests.map(\.skippingBlockers) == [false])
        #expect(fixture.instance.activity.liveSessionID == fixture.session)
    }

    @Test("Restart All reports a shutdown the guest's apps blocked as undone, naming them")
    func restartAllReportsABlockedShutdown() async throws {
        let fixture = try await makeFixture { _ in [.accepted, .finished(.blocked(Self.blocking))] }
        let (folder, _) = try makeFolder(fixture)

        let report = try await fixture.harness.core.groupAction(.restart, on: folder)

        #expect(report.results.last?.outcome == .passedOver(reason: .state))
        #expect(report.undone.map(\.vm.name) == ["Routed"])
        #expect(report.undoneTitle == "Couldn\u{2019}t Restart Every VM in \u{201C}Lab\u{201D}")
        #expect(
            report.undoneMessage.hasPrefix(
                "Couldn\u{2019}t restart Routed: Text Editor and Terminal are blocking it."))
        #expect(fixture.harness.virtualization.startCallCount == 0)
        #expect(fixture.instance.status == .running)
        #expect(fixture.instance.activity.liveSessionID == fixture.session)
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

    private static func copy(_ reason: GuestShutdownNotCarriedOut.Reason) -> (title: String?, message: String?) {
        let error = GuestShutdownNotCarriedOut(vmName: "Fedora", reason: reason)
        return (error.alertTitle, error.errorDescription)
    }

    @Test("Apps blocking the shutdown are named, and Force Stop is how to shut it down anyway")
    func blockedCopy() {
        let forceStop = " To shut it down anyway, use Force Stop, which loses any unsaved data inside the guest."
        let one = Self.copy(.blocked([AppValue(displayName: "Text Editor")], skippable: false))
        #expect(one.title == "\u{201C}Fedora\u{201D} Didn\u{2019}t Shut Down")
        #expect(one.message == "Text Editor is blocking it." + forceStop)
        #expect(
            Self.copy(.blocked(Self.blocking, skippable: false)).message
                == "Text Editor and Terminal are blocking it." + forceStop)
        let three = Self.blocking + [AppValue(displayName: "", identifier: "firefox")]
        #expect(
            Self.copy(.blocked(three, skippable: false)).message
                == "Text Editor, Terminal, and firefox are blocking it." + forceStop)
        #expect(Self.copy(.blocked([], skippable: false)).message == "An app is blocking it." + forceStop)
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
                == "Kernova can\u{2019}t tell whether \u{201C}Fedora\u{201D} is shutting down. If it doesn\u{2019}t stop, use Force Stop."
        )
    }
}
