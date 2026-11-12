import Dispatch
import KernovaSynchronization
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

/// Gives up the processor so another thread can run.
private func yieldProcessor() {
    #if canImport(WinSDK)
    _ = SwitchToThread()
    #else
    sched_yield()
    #endif
}

@Suite("Locked")
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
                yieldProcessor()
                value = read + 1
            }
        }
        #expect(counter.withLock { $0 } == iterations)
    }
}
