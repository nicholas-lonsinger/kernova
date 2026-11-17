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
        let release = DispatchSemaphore(value: 0)
        let returned = Locked(false)
        // deadline-under-test - the deadline firing is the asserted outcome
        let backstop = Backstop("an operation that blocks its thread", timeout: 0.1)
        await #expect(throws: TestFailure.self) {
            try await backstop.run {
                block(until: release)
                returned.withLock { $0 = true }
            }
        }
        #expect(!returned.withLock { $0 }, "the run waited for its operation")
        release.signal()
    }

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
