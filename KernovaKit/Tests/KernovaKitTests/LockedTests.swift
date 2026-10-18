import Foundation
import KernovaSynchronization
import KernovaTestSupport
import Testing

@Suite("Locked", .caseScoped)
struct LockedTests {
    private struct Refusal: Error, Equatable {
        let code: Int
    }

    @Test("Concurrent read-modify-writes each see the previous one's result")
    func concurrentMutationIsExclusive() {
        let counter = Locked(0)
        let iterations = 2_000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            counter.withLock { value in
                // Read, yield, then write: without exclusion another thread's
                // increment lands between the two and is lost.
                let read = value
                sched_yield()
                value = read + 1
            }
        }
        #expect(counter.withLock { $0 } == iterations)
    }

    @Test("withLock returns what its body returns")
    func returnsTheBodysResult() {
        let names = Locked(["a"])
        let count = names.withLock { names -> Int in
            names.append("b")
            return names.count
        }
        #expect(count == 2)
        #expect(names.withLock { $0 } == ["a", "b"])
    }

    @Test("withLock rethrows its body's error at the body's own type, keeping what it wrote")
    func propagatesTypedThrows() {
        let value = Locked(1)
        // The `catch` binding is `Refusal`, not `any Error`: the typed throw
        // reaches the caller unconverted.
        let caught: Refusal? = {
            do throws(Refusal) {
                try value.withLock { (value: inout Int) throws(Refusal) in
                    value = 2
                    throw Refusal(code: 7)
                }
                return nil
            } catch {
                return error
            }
        }()
        #expect(caught == Refusal(code: 7))
        #expect(value.withLock { $0 } == 2)
    }
}
