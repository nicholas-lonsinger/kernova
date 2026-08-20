import Foundation
import Testing

@testable import KernovaTestSupport

/// The gate's own invariants. It is the thing that decides how much of a bundle
/// runs at once, so a lost or duplicated permit would either stall a run or
/// quietly disable the bound it exists to impose.
@Suite("TestAdmissionGate")
struct TestAdmissionGateTests {
    // RATIONALE: sanctioned no-signal polls (docs/TESTING.md "Async waits in
    // tests") — `waiterCountForTesting` is NSLock-guarded state inside the
    // subject, and a caller reaching `acquire()`'s suspension point publishes
    // nothing a test could arm on. Queuing is the one thing that cannot be
    // observed any other way, since awaiting the caller would suspend the test.

    @Test("permits beyond the width queue instead of admitting")
    func widthBoundsConcurrentHolders() async throws {
        let gate = TestAdmissionGate(width: 2)

        await gate.acquire()
        await gate.acquire()
        #expect(gate.availableForTesting == 0)

        let third = Task { await gate.acquire() }
        try await waitUntil { gate.waiterCountForTesting == 1 }

        gate.release()
        await third.value
        #expect(gate.waiterCountForTesting == 0)
        // The released permit went straight to the waiter rather than back to
        // the pool, so nothing is free while two holders remain.
        #expect(gate.availableForTesting == 0)

        gate.release()
        gate.release()
        #expect(gate.availableForTesting == 2)
    }

    @Test("a release with nobody queued returns the permit to the pool")
    func releaseWithoutWaitersRestoresThePool() async {
        let gate = TestAdmissionGate(width: 1)
        await gate.acquire()
        #expect(gate.availableForTesting == 0)

        gate.release()
        #expect(gate.availableForTesting == 1)
        #expect(gate.waiterCountForTesting == 0)
    }

    @Test("waiters are admitted in arrival order")
    func waitersResumeFIFO() async throws {
        let gate = TestAdmissionGate(width: 1)
        await gate.acquire()
        let order = OrderLog()

        // Each task is queued before the next is started, so arrival order is
        // the order they were created in — the property `release()` promises.
        var tasks: [Task<Void, Never>] = []
        for index in 0..<3 {
            tasks.append(
                Task {
                    await gate.acquire()
                    order.record(index)
                })
            try await waitUntil { gate.waiterCountForTesting == index + 1 }
        }

        // One release at a time, each awaited before the next. Releasing all
        // three together would pin only the order they are *dequeued* in: the
        // three resumed tasks then reach `record` on whatever pool threads pick
        // them up, in any order, so the log could read [1, 0, 2] with the gate
        // behaving exactly as documented. Waiting on the log rather than on
        // `tasks[expected]` keeps a wrong admission a failed expectation rather
        // than a wait for a task that was never given a permit.
        for expected in 0..<3 {
            gate.release()
            try await order.gate.wait { order.entries.count == expected + 1 }
            #expect(order.entries.last == expected)
        }
        for task in tasks { await task.value }

        #expect(order.entries == [0, 1, 2])
    }

    @Test("a width below one admits nobody and queues every caller")
    func nonPositiveWidthAdmitsNobody() async throws {
        let gate = TestAdmissionGate(width: 0)
        #expect(gate.availableForTesting == 0)

        let queued = Task { await gate.acquire() }
        try await waitUntil { gate.waiterCountForTesting == 1 }

        // Only a release can start anyone; the gate never invents a permit.
        gate.release()
        await queued.value
        #expect(gate.availableForTesting == 0)
    }

    /// A `Sendable` log of the order waiters resumed in.
    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [Int] = []
        let gate = AsyncGate()
        func record(_ step: Int) {
            lock.withLock { steps.append(step) }
            gate.notify()
        }
        var entries: [Int] { lock.withLock { steps } }
    }
}
