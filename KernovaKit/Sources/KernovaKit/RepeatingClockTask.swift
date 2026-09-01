import Foundation

/// Runs `body` every `interval` seconds on `clock` until the returned task is
/// cancelled.
///
/// The one cancellation-checked sleep loop behind the control channel's
/// heartbeat and liveness timers on both peers. The task is unisolated, so a
/// `@MainActor` caller's `body` hops in per call instead of holding the actor
/// across the sleep.
public func repeatingClockTask(
    clock: any EngineClock,
    every interval: TimeInterval,
    _ body: @escaping @Sendable () async -> Void
) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await body()
        }
    }
}
