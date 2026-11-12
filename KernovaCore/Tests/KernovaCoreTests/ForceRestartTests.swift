import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Force Restart: Force Stop's termination, asked on every use, then the
/// boot Restart owes the session's end.
@Suite("Force Restart", .serialized, .caseScoped)
@MainActor
struct ForceRestartTests {
    private let preferences = makeTestPreferences()

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>

    private func makeHarness() -> Harness {
        Harness(WiredCommandCore(virtualization: MockVirtualizationService(), preferences: preferences))
    }

    private func forceRestart(_ harness: Harness, _ instance: VMInstance, consent: Consent) async throws {
        try await harness.core.restart(.id(instance.id), disposition: .force, timeout: nil, consent: consent)
    }

    @Test("Where Force Stop is not offered, it is refused by state, before any question")
    func refusedWhereForceStopIsNot() async throws {
        let harness = makeHarness()
        let instance = harness.wired.register(name: "Stopped", phase: .stopped)
        #expect(!harness.library.capabilities.isApplicable(.forceStop, to: instance))

        let error = try await #require(throws: CommandError.self) {
            try await forceRestart(harness, instance, consent: .none)
        }
        guard case .invalidState = error else {
            Issue.record("Expected the state refusal, got \(error)")
            return
        }
        #expect(harness.virtualization.forceStopCallCount == 0)
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("The intent gateway's restart is refused for Force Restart's consent without one, and restarts with one")
    func intentGatewayRoute() async throws {
        let harness = makeHarness()
        let instance = harness.wired.register(name: "Shortcut", phase: .running(sessionID: UUID()))
        let gateway = VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}), index: MockVMEntityIndex(),
            record: makeTestIndexRecord())

        let declined = try await #require(throws: CommandError.self) {
            try await gateway.restart(instance.id, disposition: .force, consent: .none)
        }
        #expect(declined.confirmationPrompt?.kind == .forceRestart)
        #expect(harness.virtualization.forceStopCallCount == 0)

        try await gateway.restart(instance.id, disposition: .force, consent: Consent([.forceRestart]))
        #expect(harness.virtualization.forceStopCallCount == 1)
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("A Force Stop that joins a Force Restart's termination in flight cancels its boot")
    func joiningForceStopCancelsTheBoot() async throws {
        let harness = makeHarness()
        let instance = harness.wired.register(name: "Joined", phase: .running(sessionID: UUID()))
        let boot = VMFollowUp(scope: .vm, rank: .ordinary, request: .start(recovery: false)) { _ in
            Issue.record("The cancelled Force Restart booted")
        }
        let termination = GatedStep()
        let forceRestartStop = Task { @MainActor in
            try await instance.activity.forceStop(continuingWith: boot) { try await termination.pass() }
        }
        try await termination.waitUntilEntered()
        #expect(instance.activity.liveSessionContinues)

        let forceStop = Task { @MainActor in
            try await instance.activity.forceStop { Issue.record("A joined Force Stop terminated again") }
        }
        await #expect(throws: VMContinuationStopped.self) { try await boot.outcome.value() }
        termination.release()
        try await forceRestartStop.value
        try await forceStop.value

        #expect(!instance.activity.liveSessionContinues)
        #expect(instance.status == .stopped)
    }
}
