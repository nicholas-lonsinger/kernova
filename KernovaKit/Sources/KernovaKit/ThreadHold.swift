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
