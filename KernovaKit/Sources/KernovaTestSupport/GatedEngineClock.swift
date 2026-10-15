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
        /// Released, with its caller held suspended until ``resume(_:)``.
        case held
        case cancelled
    }

    /// One parked `sleep` call: its identity, what it asked for, and the
    /// continuation to resume once the test releases it.
    ///
    /// A reference type so the continuation can be filled in after the sleeper
    /// is registered; it is mutated only under the lock, and only while
    /// ``sleepers`` still holds it.
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

    /// Continuations of sleeps released by ``releaseHeld(_:)``, kept until
    /// ``resume(_:)``; `nil` while the caller has not reached its park yet.
    private var held: [Int: CheckedContinuation<Void, Error>?] = [:]

    /// Held sleeps ``resume(_:)`` reached before their caller parked.
    private var resumedEarly: Set<Int> = []

    /// The task each ``schedule(after:_:)`` call returned, by sleep id.
    private var scheduled: [Int: Task<Void, Never>] = [:]

    /// Fires whenever a `sleep` call parks; await it instead of polling
    /// ``parked`` or ``requestedSeconds``.
    public let sleepRequested = AsyncGate()

    /// Fires whenever ``parked`` changes — a sleep parking, or one released or
    /// cancelled — so a test can await a superseded timer leaving it.
    public let parkedChanged = AsyncGate()

    /// Creates a clock with no parked sleeps.
    public init() {}

    /// The reading as last advanced; zero until a test moves it.
    public var now: EngineInstant {
        EngineInstant(nanoseconds: lock.withLock { nanoseconds })
    }

    /// Moves the reading forward by `seconds`, ageing every deadline measured
    /// against this clock without releasing anything parked on it.
    public func advance(seconds: TimeInterval) {
        let span = schedulable(seconds)
        lock.withLock { nanoseconds &+= UInt64(span * 1_000_000_000) }
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

    /// Releases a parked sleep but holds its caller suspended until
    /// ``resume(_:)``, so a test can act between the interval passing and the
    /// caller running on — cancelling a timer whose sleep has already passed.
    ///
    /// The sleep leaves ``parked`` here; cancelling its caller afterwards no
    /// longer makes the sleep throw.
    public func releaseHeld(_ sleep: ParkedSleep) {
        settle(id: sleep.id, as: .held)
    }

    /// Lets the caller of a sleep released by ``releaseHeld(_:)`` run on.
    public func resume(_ sleep: ParkedSleep) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard let entry = held.removeValue(forKey: sleep.id) else { return nil }
            guard let continuation = entry else {
                resumedEarly.insert(sleep.id)
                return nil
            }
            return continuation
        }
        continuation?.resume()
    }

    /// Waits until the work ``schedule(after:_:)`` armed with `sleep` has
    /// finished — run, or returned without running.
    public func completion(of sleep: ParkedSleep) async {
        await lock.withLock { scheduled[sleep.id] }?.value
    }

    /// Parks until the test releases this call, throwing `CancellationError` if
    /// the task is cancelled first.
    public func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        try await park(register(interval))
    }

    /// Parks `body` until the test releases it, recording the arming before
    /// this returns — so ``parked`` and ``requestedSeconds`` already show a
    /// timer the code under test armed synchronously.
    public func schedule(
        after interval: TimeInterval, _ body: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let id = register(interval)
        let task = Task {
            do { try await park(id) } catch { return }
            await body()
        }
        lock.withLock { scheduled[id] = task }
        return task
    }

    /// Records a sleep of `interval` as parked and announces it.
    private func register(_ interval: TimeInterval) -> Int {
        let id: Int = lock.withLock {
            let id = nextID
            nextID += 1
            sleepers.append(Sleeper(id: id, seconds: interval))
            requested.append(interval)
            return id
        }
        sleepRequested.notify()
        parkedChanged.notify()
        return id
    }

    /// Suspends until the sleep `id` is released, throwing `CancellationError`
    /// if the task is cancelled first.
    private func park(_ id: Int) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // A release or a cancellation racing this registration settles
                // the sleep before there is a continuation to resume, so it
                // leaves the outcome here for us to act on instead.
                let early: Outcome? = lock.withLock {
                    guard let outcome = settledEarly.removeValue(forKey: id) else {
                        sleepers.first { $0.id == id }?.continuation = continuation
                        return nil
                    }
                    guard outcome == .held, resumedEarly.remove(id) == nil else { return outcome }
                    held[id] = continuation
                    return nil
                }
                switch early {
                case .released, .held: continuation.resume()
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
        let removed: Sleeper? = lock.withLock {
            guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            let sleeper = sleepers.remove(at: index)
            if outcome == .held { held[id] = .some(sleeper.continuation) }
            if sleeper.continuation == nil { settledEarly[id] = outcome }
            return sleeper
        }
        guard let removed else { return }
        parkedChanged.notify()
        guard let continuation = removed.continuation else { return }
        switch outcome {
        case .released: continuation.resume()
        case .held: break
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
    }
}
