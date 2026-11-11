import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaSynchronization
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

    // MARK: - Copy

    private static func copy(_ reason: GuestShutdownNotCarriedOut.Reason) -> (title: String?, message: String?) {
        let error = GuestShutdownNotCarriedOut(vmName: "Fedora", session: UUID(), reason: reason)
        return (error.alertTitle, error.errorDescription)
    }

    @Test("Apps blocking the shutdown are named, and Force Stop is how to shut it down anyway")
    func blockedCopy() {
        let forceStop =
            " To shut it down anyway, use Force Stop, which loses anything in the guest that isn\u{2019}t saved to disk."
        let one = Self.copy(.blocked([AppValue(displayName: "Text Editor")]))
        #expect(one.title == "\u{201C}Fedora\u{201D} Didn\u{2019}t Shut Down")
        #expect(one.message == "Text Editor is blocking it." + forceStop)
        #expect(Self.copy(.blocked(Self.blocking)).message == "Text Editor and Terminal are blocking it." + forceStop)
        let three = Self.blocking + [AppValue(displayName: "", identifier: "firefox")]
        #expect(Self.copy(.blocked(three)).message == "Text Editor, Terminal, and firefox are blocking it." + forceStop)
        #expect(Self.copy(.blocked([])).message == "An app is blocking it." + forceStop)
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
