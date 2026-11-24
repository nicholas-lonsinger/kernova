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

    /// What a Find's next action acts on: a shortcut that deletes each VM it
    /// finds, with Delete Immediately on and Confirm Before off, loses every
    /// VM a wrong answer names.
    @Test("Find's Network and Tags conditions answer what kernova list --network and --tag list, under All or Any")
    func findMatchesNetworksAndTagsAsTheListingDoes() async throws {
        let harness = WiredCommandCore()
        let lab = try harness.core.createNetwork(name: "Lab", kind: .hostOnly)
        let prod = try harness.library.createTag(named: "Prod", color: .blue)
        harness.register(name: "On Lab") {
            $0.applyNetworkMode(.hostOnly)
            $0.networkMembership = .network(lab.id)
        }
        harness.register(name: "Common", hostState: VMHostState(tags: [prod.id])) { $0.applyNetworkMode(.nat) }
        harness.register(name: "Off")
        let gateway = makeGateway(over: harness)

        func found(
            _ conditions: [VMEntityQuery.Condition], mode: EntityQueryComparatorMode = .and
        ) async throws -> [String] {
            try await gateway.vms(meeting: conditions, mode: mode).map(\.name)
        }

        #expect(try await found([.onNetwork("lab")]) == ["On Lab"])
        #expect(try await found([.onNetwork(lab.id.uuidString)]) == ["On Lab"])
        #expect(try await found([.onNetwork("nat")]) == ["Common"])
        #expect(try await found([.onNetwork("Lab").negated]) == ["Common", "Off"])
        #expect(try await found([.carrying(tag: "prod")]) == ["Common"])
        #expect(try await found([.carrying(tag: "Prod").negated]) == ["On Lab", "Off"])
        #expect(try await found([.onNetwork("Lab"), .carrying(tag: "Prod")]).isEmpty)
        #expect(try await found([.onNetwork("Lab"), .carrying(tag: "Prod")], mode: .or) == ["On Lab", "Common"])
        // Refused as `kernova list --tag Staging` is, rather than finding none.
        await #expect(throws: CommandError.self) { try await found([.carrying(tag: "Staging")]) }
    }

    /// A shortcut that deletes the one VM a Find sorted by Last Run, oldest
    /// first, answers loses whichever VM a wrong order puts first.
    @Test("Find with no sort answers library order; Date Created and Last Run sort as kernova list --sort, or reversed")
    func findSortsAsTheListingDoes() async throws {
        let harness = WiredCommandCore()
        func register(_ name: String, created: TimeInterval, lastRun: TimeInterval?, running: Bool = false) {
            harness.register(
                name: name, phase: running ? .running(sessionID: UUID()) : .stopped,
                hostState: VMHostState(lastRunAt: lastRun.map(Date.init(timeIntervalSince1970:)))
            ) { $0.createdAt = Date(timeIntervalSince1970: created) }
        }
        register("Beta", created: 100, lastRun: nil)
        register("Older", created: 400, lastRun: 300)
        register("Alpha", created: 100, lastRun: nil)
        // Running now since before every other VM last ran.
        register("Running", created: 200, lastRun: 50, running: true)
        register("Recent", created: 300, lastRun: 500)
        let library = try await makeGateway(over: harness).vms(meeting: [], mode: .and)

        func sorted(by key: PartialKeyPath<VMEntity>, ascending: Bool) -> [String] {
            VMEntityQuery.sorted(library, by: key, ascending: ascending).map(\.name)
        }

        #expect(VMEntityQuery.ordered(library, by: [], limit: 2).map(\.name) == ["Beta", "Older"])
        #expect(sorted(by: \VMEntity.$lastRunAt, ascending: false) == ["Running", "Recent", "Older", "Alpha", "Beta"])
        #expect(sorted(by: \VMEntity.$lastRunAt, ascending: true) == ["Beta", "Alpha", "Older", "Recent", "Running"])
        // Beta and Alpha were created together, so they keep library order.
        #expect(sorted(by: \VMEntity.$createdAt, ascending: false) == ["Older", "Recent", "Running", "Beta", "Alpha"])
        #expect(sorted(by: \VMEntity.$createdAt, ascending: true) == ["Alpha", "Beta", "Running", "Recent", "Older"])
    }
}
