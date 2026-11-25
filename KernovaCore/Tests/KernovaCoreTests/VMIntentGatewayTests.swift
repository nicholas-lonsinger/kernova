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
/// Driven through the gateway rather than through `VMEntityQuery`'s methods,
/// which forward through a `@Dependency` that resolves only inside a live
/// intent session.
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

    // MARK: - Find

    /// A shortcut acts on every VM its Find answers, so a condition answering
    /// another set hands its next action VMs nobody asked for.
    @Test("Find's negated conditions answer every VM kernova list does not list, and a name it doesn't list is refused")
    func findNegatesAndRefusesAsTheListingDoes() async throws {
        let harness = WiredCommandCore()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .hostOnly)
        let gone = try harness.core.createNetwork(name: "Gone", kind: .nat)
        try harness.core.deleteNetwork(gone.id.uuidString)
        let prod = try harness.library.createTag(named: "Prod", color: .blue)
        harness.register(name: "On Lab") {
            $0.applyNetworkMode(.hostOnly)
            $0.networkMembership = .network(lab.id)
        }
        harness.register(name: "Common", hostState: VMHostState(tags: [prod.id])) { $0.applyNetworkMode(.nat) }
        harness.register(name: "Off", guestOS: .macOS)
        // Brought from another Mac, or back by a snapshot taken before its
        // network was deleted: no other condition finds it.
        harness.register(name: "Unlisted") {
            $0.applyNetworkMode(.nat)
            $0.networkMembership = .network(gone.id)
        }
        let gateway = makeGateway(over: harness)

        func found(_ condition: VMEntityQuery.Condition) async throws -> [String] {
            try await gateway.vms(meeting: [condition], mode: .and).map(\.name)
        }

        #expect(try await found(.onNetwork("lab").negated) == ["Common", "Off", "Unlisted"])
        #expect(try await found(.inMembership("Lab").negated) == ["Common", "Off", "Unlisted"])
        #expect(try await found(.inMembership(gone.id.uuidString)) == ["Unlisted"])
        #expect(try await found(.carrying(tag: "prod").negated) == ["On Lab", "Off", "Unlisted"])
        #expect(try await found(.admitted(by: VMLibraryFilter(guestOSes: [.linux]), holding: false)) == ["Off"])
        // Refused rather than answering every VM: a network since deleted, a
        // mode's word, which names no network, a membership nothing spells,
        // and a tag the library doesn't define.
        let refused: [VMEntityQuery.Condition] = [
            .onNetwork("Gone"), .onNetwork("nat"), .inMembership("comon"), .carrying(tag: "Staging"),
        ]
        for condition in refused {
            await #expect(throws: CommandError.self) { try await found(condition.negated) }
        }
    }

    /// A Find whose picker value stands for another library value answers
    /// that value's VMs, which the shortcut's next action takes as the ones
    /// it asked for.
    @Test("Each Shortcuts picker value stands for the library value of its own name, both ways")
    func pickerValuesStandForTheirLibraryValues() {
        for status in VMReportedStatus.allCases {
            #expect(VMState(status).rawValue == status.rawValue)
        }
        for status in VMAgentStatus.allCases {
            #expect(VMGuestAgentStatus(status).rawValue == status.rawValue)
        }
        for bucket in VMStateBucket.allCases {
            #expect(VMStateGroup(bucket).rawValue == bucket.rawValue)
            #expect(VMStateGroup(bucket).bucket == bucket)
        }
        for os in VMGuestOS.allCases {
            #expect(VMGuestOperatingSystem(os).rawValue == os.rawValue)
            #expect(VMGuestOperatingSystem(os).os == os)
        }
        for mode in VMNetworkMode.allCases {
            #expect(VMNetworkModeOption(mode).rawValue == mode.rawValue)
        }
        for bucket in VMGuestAgentBucket.allCases {
            #expect(VMGuestAgentVersion(bucket).rawValue == bucket.rawValue)
            #expect(VMGuestAgentVersion(bucket).bucket == bucket)
        }
    }
}
