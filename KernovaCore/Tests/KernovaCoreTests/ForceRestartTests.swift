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

    @Test("Without consent it asks, in Force Stop's terms reworded for a restart, and terminates nothing")
    func asksEveryTime() async throws {
        let harness = makeHarness()
        let instance = harness.wired.register(name: "Forced", phase: .running(sessionID: UUID()))

        let error = try await #require(throws: CommandError.self) {
            try await forceRestart(harness, instance, consent: .none)
        }
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt == VMCommandCore.forceRestartPrompt(instance))
        #expect(prompt.kind == .forceRestart)
        #expect(prompt.title == "Force Restart \u{201C}Forced\u{201D}?")
        #expect(
            prompt.message
                == "\u{201C}Forced\u{201D} will be immediately terminated, then Kernova starts it again. "
                + "Any unsaved data inside the guest will be lost.")
        #expect(prompt.confirmTitle == "Force Restart")
        #expect(prompt.confirmIsDestructive)
        #expect(prompt.dismissTitle == "Cancel")
        // Force Stop's consent is not Force Restart's.
        await #expect(throws: CommandError.self) {
            try await forceRestart(harness, instance, consent: Consent([.forceStop]))
        }
        #expect(harness.virtualization.forceStopCallCount == 0)
        #expect(harness.virtualization.startCallCount == 0)
        #expect(instance.status == .running)
    }

    @Test("With consent it force-stops the guest, presses no shutdown, and boots it again")
    func terminatesThenBoots() async throws {
        let harness = makeHarness()
        let instance = harness.wired.register(name: "Forced", phase: .running(sessionID: UUID()))

        try await forceRestart(harness, instance, consent: Consent([.forceRestart]))

        #expect(harness.virtualization.forceStopCallCount == 1)
        #expect(harness.virtualization.stopCallCount == 0)
        #expect(harness.virtualization.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("A paused guest is terminated where it is, with no resume first, and booted")
    func pausedIsTerminatedWithoutAResume() async throws {
        let harness = makeHarness()
        let instance = harness.wired.register(name: "Paused", phase: .livePaused(sessionID: UUID()))
        #expect(harness.library.capabilities.isAvailable(.forceStop, on: instance))

        try await forceRestart(harness, instance, consent: .all)

        #expect(harness.virtualization.resumeCallCount == 0)
        #expect(harness.virtualization.forceStopCallCount == 1)
        #expect(harness.virtualization.startCallCount == 1)
        #expect(instance.status == .running)
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

    @Test("A Force Restart while a Restart waits ends the session both are owed, and the guest boots once")
    func joinsAWaitingRestart() async throws {
        let harness = makeHarness()
        harness.virtualization.guestIgnoresShutdownRequest = true
        let instance = harness.wired.register(name: "Joined", phase: .running(sessionID: UUID()))

        let restart = Task { @MainActor in
            try await harness.core.restart(
                .id(instance.id), disposition: .graceful, timeout: nil, consent: .none)
        }
        try await harness.virtualization.stopRequested.wait { harness.virtualization.stopCallCount == 1 }
        try await waitForChange {
            !instance.activity.isRequestingStop && instance.activity.liveSessionContinues
        }

        try await forceRestart(harness, instance, consent: .all)
        try await restart.value

        #expect(harness.virtualization.forceStopCallCount == 1)
        #expect(harness.virtualization.startCallCount == 1)
        #expect(instance.status == .running)
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

    @Test("Shortcuts' one method type names every disposition for Stop and Restart alike")
    func intentMethodsMirrorEveryDisposition() {
        #expect(VMStopMethod.allCases.map(\.disposition) == [.graceful, .anyway, .force])
        for disposition in StopDisposition.allCases {
            #expect(VMStopMethod(disposition).disposition == disposition)
        }
    }
}
