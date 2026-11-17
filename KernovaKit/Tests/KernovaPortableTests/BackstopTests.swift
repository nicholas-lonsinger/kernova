import Dispatch
import KernovaSynchronization
import Testing

@testable import KernovaPortableTestSupport

/// A failure an operation throws, told apart from the backstop's own.
private struct Refusal: Error, Equatable {}

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
        let late = Locked<(@Sendable (Int) -> Void)?>(nil)
        // deadline-under-test - the deadline firing is the asserted outcome
        let backstop = Backstop("a callback made after the deadline", timeout: 0.1)
        await #expect(throws: TestFailure.self) {
            let _: Int = try await backstop.park { resume in late.withLock { $0 = resume } }
        }
        late.withLock { $0 }?(3)
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

    @Test("A park answers what its callback was given, and a run what its operation returns or throws")
    func passesThroughWhatArrivesInTime() async throws {
        let queue = DispatchQueue(label: "app.kernova.tests.backstop")
        #expect(try await Backstop("a queued callback").park { resume in queue.async { resume(7) } } == 7)
        #expect(try await Backstop("an operation").run { 8 } == 8)
        await #expect(throws: Refusal()) {
            let _: Int = try await Backstop("an operation that throws").run { throw Refusal() }
        }
    }

    @Test("A blocking wait takes a signal, and fails at its deadline, naming the wait, when none comes")
    func blockingWait() throws {
        let semaphore = DispatchSemaphore(value: 0)
        semaphore.signal()
        try Backstop("a signalled semaphore").wait(for: semaphore)
        // deadline-under-test - the deadline firing is the asserted outcome
        let backstop = Backstop("a semaphore nothing signals", timeout: 0.1)
        let failure = #expect(throws: TestFailure.self) { try backstop.wait(for: semaphore) }
        #expect(failure?.message.hasPrefix("a semaphore nothing signals (") == true)
    }

    @Test("A fired backstop says how late it fired and how long the system slept, hinting at machine state past bounds")
    func diagnosis() {
        #expect(backstopDiagnosis(timeout: 60, continuousElapsed: 59.5, uptimeElapsed: 59.5) == "")
        #expect(
            backstopDiagnosis(timeout: 60, continuousElapsed: 61.5, uptimeElapsed: 61.5)
                == " (backstop fired 1.50 s past its deadline; the system slept 0.00 s of the wait)")
        #expect(
            backstopDiagnosis(timeout: 60, continuousElapsed: 70.25, uptimeElapsed: 64)
                == " (backstop fired 10.25 s past its deadline; the system slept 6.25 s of the wait — consider machine"
                + " state (system sleep, display-off idle throttling, process suspension) alongside a stuck condition)")
    }
}
