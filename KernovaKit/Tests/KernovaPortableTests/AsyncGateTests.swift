import KernovaPortableTestSupport
import KernovaSynchronization
import Testing

@Suite("AsyncGate", .timeLimit(.minutes(1)))
struct AsyncGateTests {
    @Test("The first evaluation that holds ends the wait, though a notify lands while it runs")
    func aNotifyDuringTheArmingCheckLeavesTheHoldingEvaluationFinal() async throws {
        let gate = AsyncGate()
        let items = Locked(0)
        var evaluations = 0
        try await gate.wait {
            evaluations += 1
            // The check made once the waiter is registered: a producer adds
            // what the predicate takes, and notifies, while it runs.
            if evaluations == 2 {
                items.withLock { $0 += 1 }
                gate.notify()
            }
            return items.withLock { items in
                guard items > 0 else { return false }
                items -= 1
                return true
            }
        }
        #expect(evaluations == 2)
    }
}
