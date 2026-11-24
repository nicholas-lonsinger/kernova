import AppIntents
import CoreSpotlight
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The App Intents front door: what Shortcuts and Spotlight see, how it
/// waits for the library, and how it addresses VMs.
///
/// Driven through the gateway rather than through `VMEntityQuery`, which holds
/// no logic of its own — it forwards, and the `@Dependency` it forwards through
/// resolves only inside a live intent session.
@Suite("VM Intent Gateway Tests", .caseScoped)
@MainActor
struct VMIntentGatewayTests {
    /// A gateway whose library read has already landed, over a real core.
    private func makeGateway(
        over harness: WiredCommandCore,
        record: VMIndexRecord = makeTestIndexRecord(),
        index: MockVMEntityIndex = MockVMEntityIndex()
    ) -> VMIntentGateway {
        VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}), index: index,
            record: record)
    }

    // MARK: - Consent

    /// A running VM's force stop carries the gentler "Stop" alternative
    /// (`VMCommandCore.forceStopPrompt`), so it is the shape that proves the
    /// retry is not gated on a prompt having no alternatives — keying on that
    /// would leave Force Stop permanently unreachable for a hung guest.
    @Test("Force-stopping a running VM confirms, alternative or not")
    func consentRetriesAForceStopThatOffersShutDown() async throws {
        let virtualization = MockVirtualizationService()
        let harness = WiredCommandCore(virtualization: virtualization)
        let vm = harness.register(name: "Hung", phase: .running(sessionID: UUID()))
        let gateway = makeGateway(over: harness)
        var asked: [ConfirmationPrompt] = []

        try await VMConsentPolicy.run(prompting: { asked.append($0) }) { consent in
            try await gateway.stop(vm.id, disposition: .force, consent: consent, givingUpAfter: nil)
        }

        #expect(asked.map(\.kind) == [.forceStop])
        #expect(asked.first?.alternatives == [ConfirmationAlternative(title: "Stop", disposition: .graceful)])
        // Forced both times: the alternative is never taken in its place.
        #expect(virtualization.forceStopCallCount == 1)
        #expect(virtualization.stopCallCount == 0)
        #expect(vm.status == .stopped)
    }

    // MARK: - Deadlines

    /// Without the deadline a stop returns as soon as the guest is asked, so
    /// the shortcut's next action — a snapshot or a clone, which a running VM
    /// takes — would capture a guest mid-shutdown.
    @Test("A stop's Give Up After reaches the core as the wait for power-off")
    func stopPassesItsDeadline() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let clock = GatedEngineClock()
        let harness = WiredCommandCore(virtualization: virtualization, clock: clock)
        let vm = harness.register(name: "Stubborn", phase: .running(sessionID: UUID()))
        let gateway = makeGateway(over: harness)

        let stop = Task {
            try await gateway.stop(vm.id, disposition: .graceful, consent: .none, givingUpAfter: 45)
        }
        // The parked sleep is the deadline; a stop with none returns without
        // ever arming one, and this wait runs out.
        try await clock.sleepRequested.wait { !clock.parked.isEmpty }
        clock.release(try #require(clock.parked.first))

        let error = try await #require(throws: CommandError.self) { try await stop.joined() }
        guard case .timedOut(_, let verb, let seconds, _) = error else {
            Issue.record("Expected a timeout refusal, got \(error)")
            return
        }
        #expect(verb == .stop)
        #expect(seconds == 45)
    }
}
