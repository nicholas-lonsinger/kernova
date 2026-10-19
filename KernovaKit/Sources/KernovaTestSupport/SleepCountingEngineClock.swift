import Foundation
import KernovaKit
import KernovaSynchronization

/// A production `EngineClock` whose `sleep` calls a test can count and await:
/// each call is counted as it starts, then suspends on the wrapped clock for
/// real.
///
/// The seam for "the subject reached its next sleep" on the clock it runs on in
/// production — `GatedEngineClock` parks every sleep instead, and
/// `TestEngineClock` never suspends.
public final class SleepCountingEngineClock: EngineClock, Sendable {
    private let base: any EngineClock
    private let count = Locked(0)

    /// Fires on every `sleep` call; await it instead of polling ``sleepCount``.
    public let sleepRequested = AsyncGate()

    /// Creates a clock that reads and sleeps on `base`.
    public init(wrapping base: any EngineClock) {
        self.base = base
    }

    /// How many `sleep` calls have started.
    public var sleepCount: Int { count.withLock { $0 } }

    /// The wrapped clock's reading.
    public var now: EngineInstant { base.now }

    /// Counts the call, then sleeps on the wrapped clock.
    public func sleep(for interval: TimeInterval) async throws {
        count.withLock { $0 += 1 }
        sleepRequested.notify()
        try await base.sleep(for: interval)
    }
}
