import Foundation
import KernovaKit

/// An `EngineClock` that parks every `sleep` until the test releases it,
/// recording the interval each caller asked for.
///
/// The seam for asserting a *cadence*: a subject sleeping here cannot take its
/// next step until the test says so, which makes "one frame per sleep of the
/// configured interval" an equality rather than a wall-clock tolerance.
///
/// `TestEngineClock` remains the seam for crossing a production time window.
/// Reach for this one when the subject runs more than one timer loop on the same
/// clock: a `sleep` that returns immediately lets the loop *not* under test
/// free-run, so a liveness watchdog sharing the clock burns through its stages
/// while the test is still asserting on the heartbeat loop. Here the loops step
/// only when released, and the reading moves only in ``advance(seconds:)`` — so
/// a deadline measured against it ages exactly as much as the test says, and
/// releasing one loop's sleep cannot age another's at all.
public final class GatedEngineClock: EngineClock, @unchecked Sendable {
    /// A `sleep` call parked on the gate.
    public struct ParkedSleep: Sendable, Equatable {
        /// Identifies the call; unique for the clock's lifetime.
        public let id: Int

        /// The interval the caller asked to sleep for, in seconds.
        public let seconds: TimeInterval
    }

    /// How a parked sleep ended.
    private enum Outcome {
        case released
        case cancelled
    }

    /// One parked `sleep` call: its identity, what it asked for, and the
    /// continuation to resume once the test releases it.
    ///
    /// A reference type so the continuation can be filled in after the sleeper
    /// is registered; it never leaves the lock.
    private final class Sleeper {
        let id: Int
        let seconds: TimeInterval
        var continuation: CheckedContinuation<Void, Error>?

        init(id: Int, seconds: TimeInterval) {
            self.id = id
            self.seconds = seconds
        }
    }

    private let lock = NSLock()
    private var sleepers: [Sleeper] = []
    private var requested: [TimeInterval] = []
    private var nanoseconds: UInt64 = 0

    /// Outcomes for sleeps settled before their continuation was installed —
    /// a release racing the registration. Consumed by that registration.
    private var settledEarly: [Int: Outcome] = [:]
    private var nextID = 1

    /// Fires whenever a `sleep` call parks; await it instead of polling
    /// ``parked`` or ``requestedSeconds``.
    public let sleepRequested = AsyncGate()

    /// Creates a clock with no parked sleeps.
    public init() {}

    /// The reading as last advanced; zero until a test moves it.
    public var now: EngineInstant {
        EngineInstant(nanoseconds: lock.withLock { nanoseconds })
    }

    /// Moves the reading forward by `seconds`, ageing every deadline measured
    /// against this clock without releasing anything parked on it.
    public func advance(seconds: TimeInterval) {
        lock.withLock { nanoseconds &+= UInt64(max(0, seconds) * 1_000_000_000) }
    }

    /// The sleeps currently parked, in the order they were requested.
    public var parked: [ParkedSleep] {
        lock.withLock { sleepers.map { ParkedSleep(id: $0.id, seconds: $0.seconds) } }
    }

    /// Every interval a caller has asked to sleep for, in request order —
    /// released and parked alike. The cadence log a test asserts against.
    public var requestedSeconds: [TimeInterval] {
        lock.withLock { requested }
    }

    /// Resumes a parked sleep, letting its caller run on.
    ///
    /// A no-op once that sleep has been released or cancelled.
    public func release(_ sleep: ParkedSleep) {
        settle(id: sleep.id, as: .released)
    }

    /// Parks until the test releases this call, throwing `CancellationError` if
    /// the task is cancelled first.
    public func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        let id: Int = lock.withLock {
            let id = nextID
            nextID += 1
            sleepers.append(Sleeper(id: id, seconds: interval))
            requested.append(interval)
            return id
        }
        sleepRequested.notify()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A release or a cancellation racing this registration settles
                // the sleep before there is a continuation to resume, so it
                // leaves the outcome here for us to act on instead.
                let early: Outcome? = lock.withLock {
                    if let outcome = settledEarly.removeValue(forKey: id) { return outcome }
                    sleepers.first { $0.id == id }?.continuation = continuation
                    return nil
                }
                switch early {
                case .released: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            settle(id: id, as: .cancelled)
        }
    }

    /// Settles the sleep with `id`, resuming its continuation outside the lock;
    /// later calls for the same `id` do nothing.
    ///
    /// A settled sleep leaves ``sleepers``, so its presence there is what makes
    /// this fire at most once per call.
    private func settle(id: Int, as outcome: Outcome) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            let sleeper = sleepers.remove(at: index)
            if sleeper.continuation == nil { settledEarly[id] = outcome }
            return sleeper.continuation
        }
        guard let continuation else { return }
        switch outcome {
        case .released: continuation.resume()
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
    }
}
