import Foundation
import KernovaKit

/// An `EngineClock` whose reading moves only when the test advances it.
///
/// Lets a test cross a production time window — a burst window, a backoff — in
/// one call instead of sleeping through it (docs/TESTING.md, "Async waits in
/// tests"). `sleep(for:)` advances the reading and returns without suspending,
/// so a subject that sleeps on this clock runs at test speed.
public final class TestEngineClock: EngineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64

    /// Creates a clock reading `startNanoseconds`.
    public init(startNanoseconds: UInt64 = 0) {
        self.nanoseconds = startNanoseconds
    }

    /// The reading as last advanced.
    public var now: EngineInstant {
        EngineInstant(nanoseconds: lock.withLock { nanoseconds })
    }

    /// Moves the reading forward by `seconds`.
    public func advance(seconds: TimeInterval) {
        lock.withLock { nanoseconds &+= UInt64(max(0, seconds) * 1_000_000_000) }
    }

    /// Advances the reading by `interval` and returns, without suspending.
    public func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        advance(seconds: interval)
    }
}
