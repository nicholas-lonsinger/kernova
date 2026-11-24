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

    @Test("The intent gateway's restart is refused for Force Restart's consent without one, and restarts with one")
    func intentGatewayRoute() async throws {
        let harness = makeHarness()
        let instance = harness.wired.register(name: "Shortcut", phase: .running(sessionID: UUID()))
        let gateway = VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}), index: MockVMEntityIndex(),
            record: makeTestIndexRecord())

        let declined = try await #require(throws: CommandError.self) {
            try await gateway.restart(instance.id, disposition: .force, consent: .none, givingUpAfter: nil)
        }
        #expect(declined.confirmationPrompt?.kind == .forceRestart)
        #expect(harness.virtualization.forceStopCallCount == 0)

        try await gateway.restart(
            instance.id, disposition: .force, consent: Consent([.forceRestart]), givingUpAfter: nil)
        #expect(harness.virtualization.forceStopCallCount == 1)
        #expect(harness.virtualization.startCallCount == 1)
    }
}
