import Dispatch
import KernovaSynchronization
import Testing

import KernovaPortableTestSupport

/// A park's `resume`, kept to call once the wait has ended.
private struct LateResume {
    var resume: (@Sendable (Int) -> Void)?
}

/// Blocks the calling thread until `release` is signalled, whatever cancels the task it runs in.
private func block(until release: DispatchSemaphore) {
    _ = release.wait(timeout: .now() + testWaitBackstop)
}

@Suite("Backstop", .timeLimit(.minutes(1)))
struct BackstopTests {
    @Test("A park nothing answers fails at its deadline, naming the wait and where it was armed")
    func parkFailsByName() async throws {
        let line = #line + 2
        // deadline-under-test - the deadline firing is the asserted outcome
        let backstop = Backstop("a callback nothing makes", timeout: 0.1)
        let failure = await #expect(throws: TestFailure.self) {
            let _: Int = try await backstop.park { _ in }
        }
        #expect(
            failure?.message.hasPrefix(
                "a callback nothing makes (KernovaPortableTests/BackstopTests.swift:\(line)) did not end within 0.1 s")
                == true)
    }

    @Test("A run returns at its deadline while its operation, which ignores cancellation, is still running")
    func runAbandonsAnOperationThatOutlivesIt() async {
        let release = AsyncGate()
        let released = Locked(false)
        let returned = Locked(false)
        // deadline-under-test - the deadline firing is the asserted outcome
        let backstop = Backstop("an operation that outlives it", timeout: 0.1)
        await #expect(throws: TestFailure.self) {
            try await backstop.run {
                // A park, which a cancel does not end.
                try await release.wait { released.withLock { $0 } }
                returned.withLock { $0 = true }
            }
        }
        #expect(!returned.withLock { $0 }, "the run waited for its operation")
        released.withLock { $0 = true }
        release.notify()
    }

    @Test("Only a park's first resume counts, and one after the wait has ended changes nothing")
    func resumesAfterTheFirstChangeNothing() async throws {
        #expect(
            try await Backstop("a callback made twice").park { resume in
                resume(1); resume(2)
            } == 1)
        let late = Locked(LateResume())
        // deadline-under-test - the deadline firing is the asserted outcome
        let backstop = Backstop("a callback made after the deadline", timeout: 0.1)
        await #expect(throws: TestFailure.self) {
            let _: Int = try await backstop.park { resume in late.withLock { $0.resume = resume } }
        }
        late.withLock(\.resume)?(3)
    }

    #if canImport(Darwin)
    // GCD caps the threads its global queues share at 64
    // (`kern.wq_max_constrained_threads`), and Darwin's cooperative pool is
    // apart from them.
    @Test("A park fails at its deadline while blocked work holds every thread GCD's global queues share")
    func expiryOutlastsAnExhaustedPool() async {
        let release = DispatchSemaphore(value: 0)
        let returned = Locked(0)
        let occupants = 80
        for _ in 0..<occupants {
            DispatchQueue.global().async {
                block(until: release)
                returned.withLock { $0 += 1 }
            }
        }
        // deadline-under-test - the deadline firing is the asserted outcome
        let backstop = Backstop("a callback nothing makes", timeout: 0.5)
        await #expect(throws: TestFailure.self) {
            let _: Int = try await backstop.park { _ in }
        }
        #expect(returned.withLock { $0 } == 0, "the park ended only once the blocked work was let go")
        for _ in 0..<occupants { release.signal() }
    }

    @Test("Blocked calls hold threads of their own, leaving GCD's global queues theirs")
    func blockedCallsLeaveThePoolAlone() async throws {
        let release = DispatchSemaphore(value: 0)
        let returned = Locked(0)
        let calls = (0..<80).map { _ in
            BlockingCall {
                block(until: release)
                returned.withLock { $0 += 1 }
            }
        }
        let returnedBeforeIt = try await Backstop("a block on a global queue").park { resume in
            DispatchQueue.global().async { resume(returned.withLock { $0 }) }
        }
        #expect(returnedBeforeIt == 0, "the block ran only once the blocked calls returned")
        for _ in calls { release.signal() }
    }
    #endif
}
