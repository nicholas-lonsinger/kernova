import Foundation
import KernovaKit

/// Manually advanced `EngineClock` for deterministic timing tests: time moves
/// only through `advance(by:)`, which resumes every parked sleeper whose
/// deadline it reaches, in deadline order.
///
/// Await `onSleep` to know a sleeper has parked before advancing — advancing
/// first leaves it parked past its own deadline.
public final class TestEngineClock: EngineClock, @unchecked Sendable {
    /// A point on the test timeline: seconds since the clock's zero.
    public struct Instant: Comparable, Sendable {
        let offset: TimeInterval

        /// Orders instants by their offset on the test timeline.
        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var sleepers: [Sleeper] = []
    private var nextID: UInt64 = 1
    /// Sleep ids cancelled before their continuation parked.
    private var preCancelled: Set<UInt64> = []
    private var onSleepStorage: (@Sendable (TimeInterval) -> Void)?

    /// Creates a clock at time zero with no sleepers.
    public init() {}

    /// Fired (on the sleeping task's thread) each time a sleeper parks, with
    /// its interval — the event a test awaits before advancing the clock.
    public var onSleep: (@Sendable (TimeInterval) -> Void)? {
        get { lock.withLock { onSleepStorage } }
        set { lock.withLock { onSleepStorage = newValue } }
    }

    /// The current manual time.
    public var now: Instant { lock.withLock { Instant(offset: current) } }

    /// Seconds from `start` to `end`; negative when `end` precedes `start`.
    public func seconds(from start: Instant, to end: Instant) -> TimeInterval {
        end.offset - start.offset
    }

    /// Parks until `advance(by:)` reaches the deadline, throwing
    /// `CancellationError` on task cancellation.
    public func sleep(for interval: TimeInterval) async throws {
        let id: UInt64 = lock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                enum Disposition { case parked, elapsed, cancelled }
                let disposition: Disposition = lock.withLock {
                    if preCancelled.remove(id) != nil { return .cancelled }
                    guard interval > 0 else { return .elapsed }
                    sleepers.append(
                        Sleeper(id: id, deadline: current + interval, continuation: continuation))
                    return .parked
                }
                switch disposition {
                case .parked: onSleep?(interval)
                case .elapsed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.cancelSleeper(id)
        }
    }

    /// Advances the test timeline, resuming every sleeper whose deadline is
    /// reached, in `(deadline, park order)` order.
    public func advance(by interval: TimeInterval) {
        let due: [Sleeper] = lock.withLock {
            current += interval
            let reached = current
            let ready = sleepers.filter { $0.deadline <= reached }
                .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            sleepers.removeAll { $0.deadline <= reached }
            return ready
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func cancelSleeper(_ id: UInt64) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                return sleepers.remove(at: index).continuation
            }
            preCancelled.insert(id)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }
}
