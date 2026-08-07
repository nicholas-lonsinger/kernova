import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("EngineClock sleep cancellation")
struct EngineClockTests {
    @Test("Monotonic sleep throws on a cancelled task even for a non-positive interval")
    func monotonicSleepThrowsWhenCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MonotonicEngineClock().sleep(for: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Continuous sleep matches: throws on a cancelled task for a past deadline")
    func continuousSleepThrowsWhenCancelled() async {
        guard #available(macOS 13.0, *) else { return }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ContinuousEngineClock().sleep(for: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("TestEngineClock")
struct TestEngineClockTests {
    /// Starts a sleeper on `clock` and returns once it has parked — advancing
    /// before then would miss it.
    private func parkedSleeper(on clock: TestEngineClock, for interval: TimeInterval) async throws
        -> Task<Void, any Error>
    {
        let gate = AsyncGate()
        let parkedFor = Box<TimeInterval?>(nil)
        clock.onSleep = { parked in
            parkedFor.value = parked
            gate.notify()
        }
        let sleeper = Task { try await clock.sleep(for: interval) }
        try await gate.wait { parkedFor.value != nil }
        #expect(parkedFor.value == interval)
        return sleeper
    }

    @Test("A parked sleeper resumes on the advance that reaches its deadline")
    func advanceResumesAParkedSleeper() async throws {
        let clock = TestEngineClock()
        let sleeper = try await parkedSleeper(on: clock, for: 5)
        clock.advance(by: 5)
        try await sleeper.value
    }

    @Test("Cancelling a parked sleeper throws")
    func cancellingAParkedSleeperThrows() async throws {
        let clock = TestEngineClock()
        let sleeper = try await parkedSleeper(on: clock, for: 5)
        sleeper.cancel()
        await #expect(throws: CancellationError.self) { try await sleeper.value }
    }

    @Test("Sleep on an already-cancelled task throws instead of parking")
    func sleepThrowsWhenCancelledBeforeParking() async {
        let clock = TestEngineClock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: 5)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Elapsed seconds come only from advance(by:)")
    func secondsMeasureTheManualTimeline() {
        let clock = TestEngineClock()
        let start = clock.now
        clock.advance(by: 2.5)
        #expect(clock.seconds(from: start, to: clock.now) == 2.5)
        #expect(clock.seconds(from: clock.now, to: start) == -2.5)
    }
}

@Suite("EngineStopwatch")
struct EngineStopwatchTests {
    @Test("Reads zero at the instant it starts, then tracks the clock it erases")
    func tracksTheClockItErases() {
        let clock = TestEngineClock()
        clock.advance(by: 10)
        let stopwatch = EngineStopwatch(clock)
        #expect(stopwatch.elapsed == 0)
        clock.advance(by: 2.5)
        #expect(stopwatch.elapsed == 2.5)
    }
}
