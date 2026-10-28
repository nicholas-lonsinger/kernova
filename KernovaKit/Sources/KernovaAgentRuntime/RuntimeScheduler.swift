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
    /// Stops the fire if it has not started; one already queued may still run.
    func cancel()
}

/// The clock and timers a runtime runs on, injected so tests drive time by hand.
public protocol RuntimeScheduler: Sendable {
    /// The current instant on the scheduler's monotonic timeline.
    var now: CoreInstant { get }
    /// Runs `fire` on `queue` once `now` has reached `at`, or later — never inside this call. The fire is
    /// armed only while the caller holds the value returned.
    func schedule(at: CoreInstant, on: DispatchQueue, _ fire: @escaping @Sendable () -> Void) -> any ScheduledFire
}

/// The platform's clock, which counts time the machine slept, and dispatch timers.
public struct SystemScheduler: RuntimeScheduler {
    /// The scheduler; it holds no state.
    public init() {}

    /// Darwin `CLOCK_MONOTONIC`, Linux `CLOCK_BOOTTIME`, Windows `QueryInterruptTimePrecise`.
    public var now: CoreInstant {
        CoreInstant(nanoseconds: kernova_monotonic_nanoseconds())
    }

    /// Arms a timer for the span until `at`. Dispatch's own clock may stop while the machine sleeps, so
    /// the fire can land late after a sleep; the core judges time on its own clock, written for that.
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

/// One timer re-armed to a state machine's next deadline: at most one fire armed, and a fire that runs
/// clears what is armed, so the turn after it arms again even when the deadline did not move.
package struct TimerSlot: Sendable {
    private var armed: CoreInstant?
    private var fire: (any ScheduledFire)?
    private var token: UInt64 = 0

    /// A slot with nothing armed.
    package init() {}

    /// Arms for `deadline` unless that is already armed, cancelling what was; `onFire` gets the token
    /// `take(_:)` checks.
    package mutating func arm(
        _ deadline: CoreInstant?, scheduler: any RuntimeScheduler, queue: DispatchQueue,
        _ onFire: @escaping @Sendable (UInt64) -> Void
    ) {
        guard deadline != armed else { return }
        disarm()
        armed = deadline
        guard let deadline else { return }
        let token = token
        fire = scheduler.schedule(at: deadline, on: queue) { onFire(token) }
    }

    /// Cancels what is armed; a fire of it already queued is refused by `take(_:)`.
    package mutating func disarm() {
        fire?.cancel()
        fire = nil
        armed = nil
        token += 1
    }

    /// Whether the fire with `token` is the one armed. It is then spent: nothing is armed.
    package mutating func take(_ token: UInt64) -> Bool {
        guard token == self.token, armed != nil else { return false }
        fire = nil
        armed = nil
        self.token += 1
        return true
    }
}
