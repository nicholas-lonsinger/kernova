import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("waitForChange Tests", .caseScoped)
@MainActor
struct WaitForChangeTests {
    @Test("A predicate that holds only once the backstop wakes the wait fails it")
    func unobservedPredicateFailsTheWait() async {
        let timeout = Duration.milliseconds(200)
        // Time passing is state no observation sees. The predicate starts
        // holding at this instant, and the wait's own deadline, taken after it,
        // is no earlier.
        let holdsFrom = ContinuousClock.now.advanced(by: timeout)
        do {
            try await waitForChange(timeout: timeout) { ContinuousClock.now >= holdsFrom }
            Issue.record("The wait returned")
        } catch let failure as TestFailure {
            #expect(failure.message.contains("held only when the backstop woke the wait"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
