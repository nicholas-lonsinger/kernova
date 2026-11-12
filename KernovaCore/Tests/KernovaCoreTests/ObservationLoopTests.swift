import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("ObservationLoop Tests", .caseScoped)
@MainActor
struct ObservationLoopTests {
    @Observable
    @MainActor
    final class Subject {
        var value: Int = 0
    }

    @MainActor
    final class Counter {
        var count = 0
        func increment() { count += 1 }
    }

    // MARK: - waitForObservedChange

    @Test("multiple independent loops can observe the same subject")
    func independentLoops() async {
        let subject = Subject()
        let counterA = Counter()
        let counterB = Counter()

        let loopA = observeRecurring(
            track: { _ = subject.value },
            apply: { counterA.increment() }
        )
        let loopB = observeRecurring(
            track: { _ = subject.value },
            apply: { counterB.increment() }
        )

        subject.value = 1
        await drainMainQueue()
        #expect(counterA.count == 1)
        #expect(counterB.count == 1)

        loopA.cancel()

        subject.value = 2
        await drainMainQueue()
        #expect(counterA.count == 1)
        #expect(counterB.count == 2)

        _ = loopB
    }
}
