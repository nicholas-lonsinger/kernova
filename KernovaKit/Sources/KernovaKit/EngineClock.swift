import Darwin
import Foundation

/// A point on the one timeline every `EngineClock` reads: nanoseconds of
/// Darwin's `CLOCK_MONOTONIC`.
///
/// Darwin's `CLOCK_MONOTONIC` advances across system sleep (unlike Linux's),
/// matching `ContinuousClock`; `CLOCK_UPTIME_RAW`/`mach_absolute_time` do not.
/// Concrete rather than per-conformance so a holder stores `any EngineClock`,
/// and every conformance — a manually advanced test clock included — measures
/// with the arithmetic below.
public struct EngineInstant: Comparable, Sendable {
    /// The reading, in nanoseconds from an arbitrary fixed origin.
    let nanoseconds: UInt64

    /// Creates an instant at `nanoseconds` on the shared timeline.
    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// Seconds from this instant to `other`; negative when `other` precedes it.
    public func seconds(to other: EngineInstant) -> TimeInterval {
        if other.nanoseconds >= nanoseconds {
            return TimeInterval(other.nanoseconds - nanoseconds) / 1_000_000_000
        }
        return -TimeInterval(nanoseconds - other.nanoseconds) / 1_000_000_000
    }

    /// Orders instants by their nanosecond reading.
    public static func < (lhs: EngineInstant, rhs: EngineInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// The current reading of the shared timeline.
    static var now: EngineInstant {
        EngineInstant(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC))
    }
}

/// Monotonic time source for the stream engine and the guest agent's liveness
/// watchdogs — `Swift.Clock`, one floor lower, so code that must run on
/// macOS 12 guests can suspend through the same seam a 13+ host does.
///
/// `sleep` MUST count time the system spends asleep, as `now` does: a
/// suspension on an uptime timebase freezes across VM save/restore, so a
/// watchdog tick sized for seconds arrives hours of `now` later — or never.
public protocol EngineClock: Sendable {
    /// The current instant.
    var now: EngineInstant { get }

    /// Suspends the current task for at least `interval` seconds, throwing
    /// `CancellationError` when the task is cancelled.
    func sleep(for interval: TimeInterval) async throws
}

extension EngineClock {
    /// Seconds elapsed from `start` to `now`.
    public func seconds(since start: EngineInstant) -> TimeInterval {
        start.seconds(to: now)
    }
}

/// The platform-default engine clock — `ContinuousClock` on macOS 13+,
/// `CLOCK_MONOTONIC` below.
///
/// The one clock-selection `#available` in production code.
public func makePlatformEngineClock() -> any EngineClock {
    if #available(macOS 13.0, *) { return ContinuousEngineClock() }
    return MonotonicEngineClock()
}

/// The engine clock every macOS 13+ system runs.
///
/// Suspends through `ContinuousClock`, which counts time asleep, matching
/// `now`'s timebase.
@available(macOS 13.0, *)
public struct ContinuousEngineClock: EngineClock {
    private let clock = ContinuousClock()

    /// Creates a continuous-clock instance.
    public init() {}

    /// The current reading of the shared timeline.
    public var now: EngineInstant { .now }

    /// Suspends via `ContinuousClock.sleep(until:)`.
    public func sleep(for interval: TimeInterval) async throws {
        try await clock.sleep(until: clock.now + .seconds(interval))
    }
}

/// The macOS 12 fallback engine clock, suspending in bounded slices because no
/// `Swift.Clock` is available to sleep on.
public struct MonotonicEngineClock: EngineClock {
    /// Creates a monotonic-clock instance.
    public init() {}

    /// The current reading of the shared timeline.
    public var now: EngineInstant { .now }

    /// Suspends until `interval` seconds of `CLOCK_MONOTONIC` time have passed.
    ///
    /// `Task.sleep(nanoseconds:)` counts uptime and freezes across system
    /// sleep, so a single call would violate this protocol's counts-time-asleep
    /// contract; sleeping in bounded slices and re-reading the deadline clock
    /// caps the post-resume overshoot at one slice.
    public func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        let clamped = min(max(interval, 0), 1_000_000_000)
        let deadline = EngineInstant(nanoseconds: now.nanoseconds &+ UInt64(clamped * 1_000_000_000))
        while true {
            let remaining = now.seconds(to: deadline)
            guard remaining > 0 else { return }
            let slice = min(remaining, 1)
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
        }
    }
}
