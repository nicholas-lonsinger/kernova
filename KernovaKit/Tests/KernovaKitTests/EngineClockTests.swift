import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit
import KernovaSynchronization

@Suite("EngineClock conformances", .caseScoped)
struct EngineClockTests {
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
        await #expect(throws: CancellationError.self) { try await task.joined() }
    }
}
