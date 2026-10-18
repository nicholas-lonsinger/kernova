import Foundation
import KernovaKit
import KernovaSynchronization

/// An `EngineClock` whose reading moves only when the test advances it.
///
/// Lets a test cross a production time window — a burst window, a backoff — in
/// one call instead of sleeping through it. `sleep(for:)` advances the reading
/// and returns without suspending, so a subject that sleeps on this clock runs
/// at test speed.
public final class TestEngineClock: EngineClock, Sendable {
    private let nanoseconds: Locked<UInt64>

    /// Creates a clock reading `startNanoseconds`.
    public init(startNanoseconds: UInt64 = 0) {
        self.nanoseconds = Locked(startNanoseconds)
    }

    /// The reading as last advanced.
    public var now: EngineInstant {
        EngineInstant(nanoseconds: nanoseconds.withLock { $0 })
    }

    /// Moves the reading forward by `seconds`.
    public func advance(seconds: TimeInterval) {
        let span = schedulable(seconds)
        nanoseconds.withLock { $0 &+= UInt64(span * 1_000_000_000) }
    }

    /// Advances the reading by `interval` and returns, without suspending.
    public func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        advance(seconds: interval)
    }
}
