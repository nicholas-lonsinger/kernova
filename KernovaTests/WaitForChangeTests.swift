import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("waitForChange Tests", .caseScoped)
@MainActor
struct WaitForChangeTests {
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
