import Dispatch
import Foundation
import KernovaPortableTestSupport
import KernovaSynchronization
import Testing

@Suite("Off-task waits", .timeLimit(.minutes(1)))
struct OffTaskWaitsTests {
    @Test("A wait that fails on a thread the case started fails that case, by name, once the wait has ended")
    func aFailureOffTheTaskFailsTheCase() async throws {
        try await withKnownIssue {
            try await OffTaskWaits.scope {
                let waits = OffTaskWaits()
                let entered = AsyncGate()
                let hasEntered = Locked(false)
                Thread {
                    waits.run {
                        hasEntered.withLock { $0 = true }
                        entered.notify()
                        let backstop = Backstop("a release nothing makes", timeout: 0.1)
                        try backstop.wait(for: DispatchSemaphore(value: 0))
                    }
                }.start()
                // The case ends with the wait still in flight.
                try await entered.wait { hasEntered.withLock { $0 } }
            }
        } matching: { issue in
            (issue.error as? TestFailure)?.message.hasPrefix(
                "a release nothing makes (KernovaPortableTests/OffTaskWaitsTests.swift:") == true
        }
    }
}
