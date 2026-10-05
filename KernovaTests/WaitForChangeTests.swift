import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@Suite("waitForChange Tests", .caseScoped)
@MainActor
struct WaitForChangeTests {
    @Observable
    @MainActor
    final class Subject {
        var value = 0
    }

    @Test("A wait returns in a turn where its predicate holds")
    func waitReturnsWhileThePredicateHolds() async throws {
        let subject = Subject()
        let waiter = Task { @MainActor in
            try await waitForChange { subject.value == 1 }
            return subject.value
        }
        await drainMainQueue()

        // The production wait answers from a main-actor task this change
        // enqueues. The flip back is enqueued behind that task and ahead of the
        // waiter's resumption.
        subject.value = 1
        Task { @MainActor in subject.value = 0 }
        await drainMainQueue()
        subject.value = 1

        #expect(try await waiter.value == 1)
    }

    @Test("A predicate that holds only once the deadline re-reads it fails the wait")
    func unobservedPredicateFailsTheWait() async {
        let timeout: TimeInterval = 0.2
        // Time passing is state no observation sees. The predicate starts
        // holding `timeout` after this reading, and the wait's deadline sleeps
        // at least that long from a later one.
        let clock = MonotonicEngineClock()
        let start = clock.now
        do {
            try await waitForChange(timeout: timeout) { clock.seconds(since: start) >= timeout }
            Issue.record("The wait returned")
        } catch let failure as TestFailure {
            #expect(failure.message.contains("held only when the deadline re-read it"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
