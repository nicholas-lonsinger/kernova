import CKernovaShims
// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch
// does not, though dispatch objects are thread-safe on every platform.
#if canImport(Darwin)
import Dispatch
#else
@preconcurrency import Dispatch
#endif
import KernovaAgentCore

/// A timer the scheduler armed.
public protocol ScheduledFire: Sendable {
    /// Stops the fire if it has not run; a fire already running finishes.
    func cancel()
}

/// The clock and timers a runtime runs on, injected so tests drive time by hand.
public protocol RuntimeScheduler: Sendable {
    /// The current instant on the scheduler's monotonic timeline.
    var now: CoreInstant { get }
    /// Runs `fire` on `queue` once `now` has reached `at`, or later.
    func schedule(at: CoreInstant, on: DispatchQueue, _ fire: @escaping @Sendable () -> Void) -> any ScheduledFire
}

/// The platform's clock, which counts time the machine slept, and dispatch timers.
public struct SystemScheduler: RuntimeScheduler {
    /// The scheduler; it holds no state.
    public init() {}

    /// Darwin `CLOCK_MONOTONIC`, Linux `CLOCK_BOOTTIME`, Windows `QueryInterruptTime`.
    public var now: CoreInstant {
        CoreInstant(nanoseconds: kernova_monotonic_nanoseconds())
    }

    /// Arms a timer for the span until `at`. Dispatch's own clock may stop while the machine sleeps, so
    /// the fire can land late after a sleep; the core's judged time (§5.2) is written for that.
    public func schedule(at deadline: CoreInstant, on queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void)
        -> any ScheduledFire
    {
        let delay = max(0, now.duration(to: deadline).nanoseconds)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler(handler: fire)
        timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: delay)))
        timer.resume()
        return DispatchFire(timer: timer)
    }
}

private struct DispatchFire: ScheduledFire {
    let timer: any DispatchSourceTimer

    func cancel() {
        timer.cancel()
    }
}
