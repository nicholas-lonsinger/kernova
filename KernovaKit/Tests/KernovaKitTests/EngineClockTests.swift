import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("EngineInstant arithmetic", .admissionGated)
struct EngineInstantTests {
    @Test("seconds(to:) converts the nanosecond gap forward")
    func secondsForward() {
        let start = EngineInstant(nanoseconds: 1_000_000_000)
        let end = EngineInstant(nanoseconds: 3_500_000_000)
        #expect(start.seconds(to: end) == 2.5)
    }

    @Test("seconds(to:) is negative when the target precedes the receiver")
    func secondsBackward() {
        let start = EngineInstant(nanoseconds: 3_500_000_000)
        let end = EngineInstant(nanoseconds: 1_000_000_000)
        #expect(start.seconds(to: end) == -2.5)
    }

    @Test("seconds(to:) is zero for the same instant")
    func secondsToSelf() {
        let instant = EngineInstant(nanoseconds: 42)
        #expect(instant.seconds(to: instant) == 0)
    }

    @Test("a gap spanning the whole UInt64 range does not overflow the subtraction")
    func secondsAcrossTheFullRange() {
        let start = EngineInstant(nanoseconds: 0)
        let end = EngineInstant(nanoseconds: .max)
        #expect(start.seconds(to: end) > 0)
        #expect(end.seconds(to: start) == -start.seconds(to: end))
    }

    @Test("instants order by their reading")
    func ordering() {
        #expect(EngineInstant(nanoseconds: 1) < EngineInstant(nanoseconds: 2))
        #expect(!(EngineInstant(nanoseconds: 2) < EngineInstant(nanoseconds: 1)))
    }
}

@Suite("EngineClock conformances", .admissionGated)
struct EngineClockTests {
    @Test("now never goes backwards", arguments: EngineClockKind.allCases)
    func nowIsMonotonic(kind: EngineClockKind) {
        let clock = kind.makeClock()
        let first = clock.now
        let second = clock.now
        #expect(!(second < first))
    }

    /// The invariant that lets a holder store `any EngineClock` and swap
    /// conformances: both read one timeline, so instants taken from one are
    /// comparable with instants taken from the other.
    @Test("both production conformances read the same timeline")
    func conformancesShareOneTimeline() {
        guard #available(macOS 13.0, *) else { return }
        let monotonic = MonotonicEngineClock()
        let continuous = ContinuousEngineClock()
        let before = monotonic.now
        let between = continuous.now
        let after = monotonic.now
        #expect(!(between < before))
        #expect(!(after < between))
    }

    @Test(
        "sleep suspends, and seconds(since:) sees the elapsed time",
        arguments: EngineClockKind.allCases)
    func sleepSuspends(kind: EngineClockKind) async throws {
        let clock = kind.makeClock()
        let start = clock.now
        #expect(clock.seconds(since: start) >= 0)
        try await clock.sleep(for: 0.1)
        // A generous lower bound, not the requested interval: the assertion is
        // that the call suspended at all, and a starved runner only overshoots.
        #expect(clock.seconds(since: start) >= 0.05)
    }

    @Test(
        "sleep throws on a cancelled task even for a non-positive interval",
        arguments: EngineClockKind.allCases)
    func sleepThrowsWhenAlreadyCancelled(kind: EngineClockKind) async {
        let clock = kind.makeClock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: 0)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(
        "cancelling mid-sleep throws instead of running out the interval",
        arguments: EngineClockKind.allCases)
    func sleepThrowsWhenCancelledMidFlight(kind: EngineClockKind) async throws {
        let clock = kind.makeClock()
        let started = AsyncGate()
        let running = Box(false)
        let task = Task {
            running.value = true
            started.notify()
            // An interval the cancellation must cut short — never waited out.
            try await clock.sleep(for: 3600)
        }
        try await started.wait { running.value }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
