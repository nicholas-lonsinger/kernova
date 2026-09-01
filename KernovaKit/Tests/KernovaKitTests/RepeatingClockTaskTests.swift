import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The one timer loop behind both peers' heartbeat and liveness tasks: what a
/// tick costs, and the two ways the loop ends.
@Suite("repeatingClockTask")
struct RepeatingClockTaskTests {
    // MARK: - Harness

    /// Counts body runs and wakes a waiter on each, so a test awaits a run
    /// rather than polling for one.
    private final class RunCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var runs = 0

        /// Fires on every `record()`.
        let changed = AsyncGate()

        var count: Int { lock.withLock { runs } }

        func record() {
            lock.withLock { runs += 1 }
            changed.notify()
        }
    }

    /// A clock that cancels the loop's own task from inside `sleep`, then
    /// returns normally.
    ///
    /// The only way to reach the window the post-sleep cancellation check
    /// closes: a cancellation landing while the sleep is elapsing leaves the
    /// loop resuming from a sleep that did not throw.
    private final class CancelDuringSleepClock: EngineClock, @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var sleeps = 0

        /// Fires once the loop's task handle is installed, so `sleep` waits for
        /// it instead of racing the caller's assignment.
        private let armed = AsyncGate()

        /// How many sleeps the loop asked for.
        var sleepCount: Int { lock.withLock { sleeps } }

        /// Hands the clock the task it is to cancel.
        func arm(_ task: Task<Void, Never>) {
            lock.withLock { self.task = task }
            armed.notify()
        }

        var now: EngineInstant { EngineInstant(nanoseconds: 0) }

        func sleep(for interval: TimeInterval) async throws {
            try await armed.wait { self.lock.withLock { self.task != nil } }
            let handle = lock.withLock { () -> Task<Void, Never>? in
                sleeps += 1
                return task
            }
            handle?.cancel()
        }
    }

    /// A clock whose every `sleep` fails — the shape a real one takes when the
    /// suspension itself cannot be scheduled.
    private struct FailingClock: EngineClock {
        struct SleepFailed: Error {}

        var now: EngineInstant { EngineInstant(nanoseconds: 0) }

        func sleep(for interval: TimeInterval) async throws {
            throw SleepFailed()
        }
    }

    // MARK: - Ticks

    @Test("Each tick is one sleep of the configured interval followed by one body run")
    func bodyRunsOncePerTick() async throws {
        let clock = GatedEngineClock()
        let runs = RunCounter()
        let task = repeatingClockTask(clock: clock, every: 3) { runs.record() }
        defer { task.cancel() }

        for round in 1...3 {
            try await clock.sleepRequested.wait { clock.parked.count == 1 }
            let parked = try #require(clock.parked.first)
            // The body is behind the sleep, so nothing has run this round yet —
            // a loop that ran first would show up here.
            #expect(parked.seconds == 3)
            #expect(runs.count == round - 1)

            clock.release(parked)

            try await runs.changed.wait { runs.count == round }
        }
        #expect(clock.requestedSeconds.allSatisfy { $0 == 3 })
    }

    // MARK: - Ending the loop

    @Test("A loop cancelled while its sleep elapsed does not run the body again")
    func cancellationDuringASleepSkipsTheBody() async throws {
        let clock = CancelDuringSleepClock()
        let runs = RunCounter()
        let task = repeatingClockTask(clock: clock, every: 1) { runs.record() }

        clock.arm(task)

        // The loop ends of its own accord — the value is the end of the loop,
        // so nothing here polls for it.
        await task.value
        #expect(clock.sleepCount == 1)
        #expect(runs.count == 0)
    }

    @Test("A sleep that throws ends the loop without running the body")
    func aThrownSleepEndsTheLoop() async throws {
        let runs = RunCounter()

        let task = repeatingClockTask(clock: FailingClock(), every: 1) { runs.record() }

        await task.value
        #expect(runs.count == 0)
    }
}
