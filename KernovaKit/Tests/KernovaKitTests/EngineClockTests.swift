import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit
@testable import KernovaTransferProgress
import KernovaSynchronization

@Suite("EngineInstant arithmetic", .caseScoped)
struct EngineInstantTests {
    @Test("a gap spanning the whole UInt64 range does not overflow the subtraction")
    func secondsAcrossTheFullRange() {
        let start = EngineInstant(nanoseconds: 0)
        let end = EngineInstant(nanoseconds: .max)
        #expect(start.seconds(to: end) > 0)
        #expect(end.seconds(to: start) == -start.seconds(to: end))
    }
}

@Suite("EngineClock conformances", .caseScoped)
struct EngineClockTests {
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
        "An interval past what the arithmetic can hold suspends instead of trapping",
        arguments: EngineClockKind.allCases)
    func hugeIntervalIsClamped(kind: EngineClockKind) async throws {
        let clock = kind.makeClock()
        // A deadline arrives from whatever a caller typed, and both the instant
        // arithmetic and the UInt64 conversion under these clocks trap on a
        // number this size — which would take the app down, not the wait.
        let ceiling = MonotonicEngineClock.maximumSleepInterval
        #expect(clock.schedulable(.greatestFiniteMagnitude) == ceiling)
        #expect(clock.schedulable(.infinity) == ceiling)
        #expect(clock.schedulable(-1) == 0)

        let started = AsyncGate()
        let running = Locked(false)
        let task = Task {
            running.withLock { $0 = true }
            started.notify()
            try await clock.sleep(for: .greatestFiniteMagnitude)
        }
        try await started.wait { running.withLock { $0 } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
