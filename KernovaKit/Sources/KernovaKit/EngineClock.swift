import Darwin
import Foundation

/// Monotonic time source for the stream engine and the guest agent's liveness
/// watchdogs — `Swift.Clock`, one floor lower, so code that must run on
/// macOS 12 guests can still store real `ContinuousClock.Instant`s on 13+.
///
/// Conformances MUST count time the system spends asleep: the liveness
/// watchdogs measure elapsed time across VM save/restore, and an uptime clock
/// (`DispatchTime`/`mach_absolute_time`) freezes there and never fires them.
public protocol EngineClock: Sendable {
    /// A point in this clock's timeline.
    associatedtype Instant: Comparable, Sendable

    /// The current instant.
    var now: Instant { get }

    /// Seconds from `start` to `end`; negative when `end` precedes `start`.
    func seconds(from start: Instant, to end: Instant) -> TimeInterval

    /// Suspends the current task for at least `interval` seconds, throwing
    /// `CancellationError` when the task is cancelled.
    func sleep(for interval: TimeInterval) async throws
}

extension EngineClock {
    /// Seconds elapsed from `start` to `now`.
    public func seconds(since start: Instant) -> TimeInterval {
        seconds(from: start, to: now)
    }
}

/// `ContinuousClock` as an `EngineClock` — the conformance every macOS 13+
/// system runs, storing genuine `ContinuousClock.Instant`s.
@available(macOS 13.0, *)
public struct ContinuousEngineClock: EngineClock {
    private let clock = ContinuousClock()

    /// Creates a continuous-clock instance.
    public init() {}

    /// The current `ContinuousClock` instant.
    public var now: ContinuousClock.Instant { clock.now }

    /// Seconds from `start` to `end`; negative when `end` precedes `start`.
    public func seconds(
        from start: ContinuousClock.Instant, to end: ContinuousClock.Instant
    ) -> TimeInterval {
        start.duration(to: end) / .seconds(1)
    }

    /// Suspends via `ContinuousClock.sleep(until:)`.
    public func sleep(for interval: TimeInterval) async throws {
        try await clock.sleep(until: clock.now + .seconds(interval))
    }
}

/// `CLOCK_MONOTONIC` as an `EngineClock` — the macOS 12 fallback.
///
/// Darwin's `CLOCK_MONOTONIC` advances across system sleep (unlike Linux's),
/// matching `ContinuousClock`; `CLOCK_UPTIME_RAW`/`mach_absolute_time` do not.
public struct MonotonicEngineClock: EngineClock {
    /// A `CLOCK_MONOTONIC` reading in nanoseconds.
    public struct Instant: Comparable, Sendable {
        let nanoseconds: UInt64

        /// Orders instants by their nanosecond reading.
        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.nanoseconds < rhs.nanoseconds
        }
    }

    /// Creates a monotonic-clock instance.
    public init() {}

    /// The current `CLOCK_MONOTONIC` reading.
    public var now: Instant {
        Instant(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC))
    }

    /// Seconds from `start` to `end`; negative when `end` precedes `start`.
    public func seconds(from start: Instant, to end: Instant) -> TimeInterval {
        if end.nanoseconds >= start.nanoseconds {
            return TimeInterval(end.nanoseconds - start.nanoseconds) / 1_000_000_000
        }
        return -TimeInterval(start.nanoseconds - end.nanoseconds) / 1_000_000_000
    }

    /// Suspends via `Task.sleep(nanoseconds:)`.
    public func sleep(for interval: TimeInterval) async throws {
        let clamped = min(max(interval, 0), 1_000_000_000)
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}
