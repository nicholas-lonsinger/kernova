import Foundation

/// Holds the calling thread until a condition resolves: on the main run loop's
/// base by running the event loop (``NestedEventLoopWait``), anywhere else by
/// parking on a semaphore that whatever resolves the condition signals from
/// another thread.
enum ThreadHold {
    /// Holds until `resolved` returns a value, re-checking it at least every
    /// `interval`, or until `deadline` passes.
    ///
    /// `resolved`, never the wait's return, decides — so a signal racing a
    /// re-check is still honored. Parked, the hold wakes only for `semaphore`,
    /// the re-check interval or the deadline; running `eventLoop`, also for
    /// its ``NestedEventLoopWait/wake()``.
    ///
    /// - Returns: the value, or `nil` once `deadline` passed without one.
    static func hold<Value>(
        eventLoop: NestedEventLoopWait?, semaphore: DispatchSemaphore,
        deadline: DispatchTime = .distantFuture,
        recheckingEvery interval: TimeInterval = .infinity,
        until resolved: @Sendable () -> Value?
    ) -> Value? {
        while true {
            if let value = resolved() { return value }
            let now = DispatchTime.now()
            guard now < deadline else { return nil }
            let remaining =
                Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
            let slice = min(interval, remaining)
            if let eventLoop {
                _ = eventLoop.wait(timeout: slice) { resolved() != nil }
            } else {
                _ = semaphore.wait(timeout: now + slice)
            }
        }
    }
}

extension ThreadHold {
    /// One hold of the calling thread, decided before the work it waits on
    /// starts: the event loop on the main run loop's base, a park on any other
    /// thread, and none at all on the main thread anywhere else.
    ///
    /// **The main thread is never parked.** Where a nested wait would have to
    /// dispatch events another loop owns — inside a tracking or modal loop —
    /// ``NestedEventLoopWait/current(slice:)`` vends none, and parking instead
    /// would freeze the app for the length of the work; so there is no hold,
    /// and the caller refuses before starting anything. Off the main thread
    /// the hold parks, so what ends it MUST come from another thread.
    struct Wait: Sendable {
        private let eventLoop: NestedEventLoopWait?
        private let semaphore = DispatchSemaphore(value: 0)

        /// The hold for the calling thread running `eventLoop`, or nil on the
        /// main thread when `eventLoop` is nil.
        init?(eventLoop: NestedEventLoopWait?) {
            guard eventLoop != nil || !Thread.isMainThread else { return nil }
            self.eventLoop = eventLoop
        }

        /// Ends the hold in progress, from any thread; a wake before the hold
        /// begins is kept.
        func wake() {
            semaphore.signal()
            eventLoop?.wake()
        }

        /// Holds until `resolved` returns a value, re-checking it at least
        /// every `interval`, or until `deadline` passes.
        ///
        /// - Returns: the value, or `nil` once `deadline` passed without one.
        func hold<Value>(
            deadline: DispatchTime, recheckingEvery interval: TimeInterval = .infinity,
            until resolved: @Sendable () -> Value?
        ) -> Value? {
            ThreadHold.hold(
                eventLoop: eventLoop, semaphore: semaphore, deadline: deadline, recheckingEvery: interval,
                until: resolved)
        }
    }
}
