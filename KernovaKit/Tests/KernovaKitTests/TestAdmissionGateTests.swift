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

        for _ in 0..<3 { gate.release() }
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
        func record(_ step: Int) { lock.withLock { steps.append(step) } }
        var entries: [Int] { lock.withLock { steps } }
    }
}
