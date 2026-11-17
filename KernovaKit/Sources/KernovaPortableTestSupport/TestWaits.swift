#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import CKernovaShims
// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch
// does not, though dispatch objects are thread-safe on every platform.
#if canImport(Darwin)
import Dispatch
#else
@preconcurrency import Dispatch
#endif
import KernovaSynchronization

// MARK: - Test-session OS activity

#if canImport(Darwin)
/// Begins the OS activity exempting the test host from App Nap and idle timer
/// throttling, on the first `armTestSessionActivity()` call — which reads this
/// precisely to run the lazy initializer — and retains its token for the rest
/// of the process's life. `.userInitiated` also keeps the machine from
/// idle-sleeping mid-run: system sleep would blow every armed backstop.
///
/// On an idle, display-off machine the OS can hold a windowless process's
/// timers past the 60 s backstop, then release every armed wait at one
/// instant, mass-failing whatever cases are in flight (observed 2026-08-06,
/// #759). Test runs are user-initiated work even when the display is off.
private let testSessionActivity: Void = {
    let token = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "Test waits measure real time and must not be throttled")
    _ = Unmanaged.passRetained(token as AnyObject)
}()
#endif

/// Begins the test session's OS activity on first call; later calls no-op, as
/// does every call off Apple platforms, which throttle no such process.
///
/// Every ``Backstop`` calls this; a wait outside them (a run-loop timer a test
/// arms) calls it directly before parking.
public func armTestSessionActivity() {
    #if canImport(Darwin)
    _ = testSessionActivity
    #endif
}

// MARK: - TestFailure

/// A test failure with a diagnostic message, thrown by the wait helpers below.
public struct TestFailure: Error, CustomStringConvertible {
    /// The diagnostic text describing what condition was not met.
    public let message: String

    /// Creates a failure carrying `message`.
    public init(_ message: String) { self.message = message }

    /// The failure's diagnostic message.
    public var description: String { message }
}

// MARK: - Backstop

/// One test wait's deadline: `timeout` seconds from when it is made, on the
/// clock that counts the time the machine sleeps.
///
/// Every wait helper here ends through one, so a condition that never arrives
/// fails its wait with ``failure(_:)``, naming the wait and where it was
/// armed, instead of stalling the run until the test plan's allowance stops
/// the process. A wait parks through ``park(isolation:_:)``, ``run(_:)`` or
/// ``wait(for:)``, and each returns at the deadline whatever the thing it
/// waits on does, abandoning it.
public struct Backstop: Sendable {
    /// Seconds from creation to the deadline.
    public let timeout: TimeInterval
    /// The wait's name and where it was armed, as its failure leads with them.
    private let wait: String
    private let continuousStart = kernova_monotonic_nanoseconds()
    private let uptimeStart = kernova_uptime_nanoseconds()

    /// Starts the deadline of the wait `name`, armed at `fileID`:`line`.
    ///
    /// A wait expecting success takes the `testWaitBackstop` default; a
    /// shorter `timeout` is for a deadline the test asserts.
    public init(
        _ name: String, timeout: TimeInterval = testWaitBackstop, fileID: String = #fileID, line: Int = #line
    ) {
        armTestSessionActivity()
        self.timeout = timeout
        wait = "\(name) (\(fileID):\(line))"
    }

    /// Seconds left until the deadline; zero or less once it has passed.
    public var remaining: TimeInterval { timeout - elapsed }

    /// Whether the deadline has passed.
    public var expired: Bool { remaining <= 0 }

    /// The failure a fired backstop throws: the wait's name and site, what did
    /// not happen in time, `detail` when given, and how late the backstop fired.
    public func failure(_ detail: String? = nil) -> TestFailure {
        let uptimeElapsed = Self.seconds(kernova_uptime_nanoseconds() &- uptimeStart)
        return TestFailure(
            "\(wait) did not end within \(timeout) s" + (detail.map { ": " + $0 } ?? "")
                + backstopDiagnosis(timeout: timeout, continuousElapsed: elapsed, uptimeElapsed: uptimeElapsed))
    }

    // `isolation` uses the Swift `isolated` keyword to run `start` in the
    // caller's isolation, so it is never referenced by name.
    // periphery:ignore:parameters isolation
    /// Suspends until `start`'s `resume` runs, answering the value it was
    /// given; throws ``failure(_:)`` once the deadline passes first, and
    /// `CancellationError` once the waiting task is cancelled first.
    ///
    /// `start` runs at once, in the caller's isolation, and hands `resume` to
    /// whatever will answer: a completion handler, a queue, a list of waiters.
    /// `resume` may run on any thread, before `start` returns included. Only
    /// its first call counts, and a call after the wait has ended changes
    /// nothing, so what the wait gave up on may still make it.
    public func park<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ start: (_ resume: @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        let parked = Parked<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                parked.install(continuation)
                start { parked.settle(.success($0)) }
                parked.arm(self)
            }
        } onCancel: {
            parked.settle(.failure(CancellationError()))
        }
    }

    /// Runs `operation` in a task of its own, answering what it returns or
    /// rethrowing what it throws; throws ``failure(_:)`` once the deadline
    /// passes first, and `CancellationError` once the waiting task is
    /// cancelled first.
    ///
    /// Either way the operation is cancelled and left to stop in its own time,
    /// so this returns at the deadline even when the operation ignores
    /// cancellation.
    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var task: Task<Void, Never>?
        defer { task?.cancel() }
        let outcome: Result<T, any Error> = try await park { resume in
            task = Task {
                do { resume(.success(try await operation())) } catch { resume(.failure(error)) }
            }
        }
        return try outcome.get()
    }

    /// Blocks the calling thread until `semaphore` is signalled, taking the
    /// signal; throws ``failure(_:)`` once the deadline passes first.
    ///
    /// Dispatch's own clock stops while the machine sleeps and this one does
    /// not, so the wait re-reads it at least once a second.
    @available(*, noasync, message: "Park through park(isolation:_:) instead of blocking a cooperative thread")
    public func wait(for semaphore: DispatchSemaphore) throws(TestFailure) {
        while true {
            if semaphore.wait(timeout: .now() + Self.slice(remaining)) == .success { return }
            if expired { throw failure() }
        }
    }

    /// Seconds of continuous time since creation.
    private var elapsed: TimeInterval { Self.seconds(kernova_monotonic_nanoseconds() &- continuousStart) }

    /// The longest a dispatch wait or timer may run before the continuous
    /// clock is read again: `remaining`, but no more than a second.
    fileprivate static func slice(_ remaining: TimeInterval) -> TimeInterval { min(max(remaining, 0), 1) }

    private static func seconds(_ nanoseconds: UInt64) -> TimeInterval { TimeInterval(nanoseconds) / 1_000_000_000 }
}

/// The parenthetical a fired backstop appends to its failure message: how far
/// past its deadline it fired (continuous time) and how much of the wait the
/// system spent asleep (continuous minus uptime elapsed), with a machine-state
/// hint once either exceeds honest-scheduling bounds — and empty when
/// `continuousElapsed` never reached `timeout` (a predicate that flapped, not a
/// fired backstop).
func backstopDiagnosis(
    timeout: TimeInterval, continuousElapsed: TimeInterval, uptimeElapsed: TimeInterval
) -> String {
    guard continuousElapsed >= timeout else { return "" }
    let late = continuousElapsed - timeout
    let slept = max(0, continuousElapsed - uptimeElapsed)
    var text =
        " (backstop fired \(hundredths(late)) s past its deadline;"
        + " the system slept \(hundredths(slept)) s of the wait"
    // System sleep is the only state this clock pair separates — App Nap-class
    // throttling and per-process suspension advance both clocks and surface as
    // lateness alone. The lateness bound scales down with short explicit
    // timeouts, and the hint stays a hint: a starved CI runner can fire an
    // honest backstop seconds late, so the numbers outrank the wording.
    if late >= min(5, timeout) || slept >= 1 {
        text +=
            " — consider machine state (system sleep, display-off idle"
            + " throttling, process suspension) alongside a stuck condition"
    }
    return text + ")"
}

/// `seconds` with two decimal places.
private func hundredths(_ seconds: TimeInterval) -> String {
    let hundredths = Int((seconds * 100).rounded())
    let fraction = String(hundredths % 100)
    return "\(hundredths / 100)." + String(repeating: "0", count: 2 - fraction.count) + fraction
}

/// One park's outcome, settled once: by what `start` handed `resume` to, by
/// the deadline, or by a cancel — whichever comes first.
private final class Parked<T: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<T, any Error>?
        var outcome: Result<T, any Error>?
        var expiry: Expiry?
    }

    private let state = Locked(State())

    /// Hands the continuation the outcome, at once when it is already settled.
    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let settled = state.withLock { state in
            if state.outcome == nil { state.continuation = continuation }
            return state.outcome
        }
        if let settled { continuation.resume(with: settled) }
    }

    /// Settles with `backstop`'s failure once it expires, unless something
    /// settles first.
    func arm(_ backstop: Backstop) {
        let expiry = Expiry(backstop) { [self] in settle(.failure(backstop.failure())) }
        let armed = state.withLock { state in
            guard state.outcome == nil else { return false }
            state.expiry = expiry
            return true
        }
        if !armed { expiry.cancel() }
    }

    /// Settles with `outcome` unless already settled.
    func settle(_ outcome: Result<T, any Error>) {
        let (continuation, expiry) = state.withLock { state in
            guard state.outcome == nil else { return (CheckedContinuation<T, any Error>?.none, Expiry?.none) }
            state.outcome = outcome
            defer { (state.continuation, state.expiry) = (nil, nil) }
            return (state.continuation, state.expiry)
        }
        expiry?.cancel()
        continuation?.resume(with: outcome)
    }
}

/// Calls `expire` once its backstop has expired, until cancelled, reading the
/// backstop's clock at least once a second. It runs on a global queue, so a
/// cooperative pool whose threads are all blocked cannot hold it back.
private final class Expiry: Sendable {
    private let timer: any DispatchSourceTimer

    init(_ backstop: Backstop, _ expire: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: .global())
        timer.setEventHandler {
            if backstop.expired { expire() }
        }
        timer.schedule(deadline: .now() + Backstop.slice(backstop.remaining), repeating: 1)
        timer.resume()
    }

    func cancel() {
        timer.cancel()
    }
}

// MARK: - Blocking calls

/// A **synchronous, blocking** bridge call, started at once on a GCD
/// global-queue thread, mirroring production's callers.
///
/// A blocking bridge call parks its thread until the transfer resolves. GCD
/// global queues overcommit, so a parked pull there costs a kernel thread; on
/// the cooperative pool (3-4 threads on CI) enough parked pulls exhaust it, the
/// tasks the reply depends on starve, and the bundle freezes until the shortest
/// injected timeout fires (observed as the 2026-07-19 CI mass failures).
public final class BlockingCall<T: Sendable>: Sendable {
    private enum State: Sendable {
        case running(waiting: [@Sendable (T) -> Void])
        case returned(T)
    }

    private let state = Locked(State.running(waiting: []))

    /// Starts `body`.
    public init(_ body: @escaping @Sendable () -> T) {
        let state = state
        DispatchQueue.global(qos: .userInitiated).async {
            let value = body()
            let waiting = state.withLock { state in
                defer { state = .returned(value) }
                guard case .running(let waiting) = state else { return [@Sendable (T) -> Void]() }
                return waiting
            }
            for resume in waiting { resume(value) }
        }
    }

    /// What the call returned, once it has; throws `Backstop.failure(_:)` when
    /// it is still blocked at the deadline, leaving it to return to nothing.
    public func value(fileID: String = #fileID, line: Int = #line) async throws -> T {
        try await Backstop("the blocking call", fileID: fileID, line: line).park { resume in
            let returned = state.withLock { state -> T? in
                switch state {
                case .running(let waiting):
                    state = .running(waiting: waiting + [resume])
                    return nil
                case .returned(let value):
                    return value
                }
            }
            if let returned { resume(returned) }
        }
    }
}

/// Runs a **synchronous, blocking** bridge call as ``BlockingCall`` does, and
/// awaits what it returns.
public func offCooperativePool<T: Sendable>(
    fileID: String = #fileID, line: Int = #line, _ body: @escaping @Sendable () -> T
) async throws -> T {
    try await BlockingCall(body).value(fileID: fileID, line: line)
}

// MARK: - AsyncGate

/// Event-driven replacement for a `waitUntil` poll loop.
///
/// A producer calls `notify()` after each observable state change; the consumer
/// awaits `wait(until:)`, which suspends until the predicate holds — re-checked
/// on every `notify()` — or throws `TestFailure` after `timeout`, a
/// stuck-condition backstop the happy path never reaches.
public final class AsyncGate: Sendable {
    private let waiters = Locked<[UUID: @Sendable () -> Void]>([:])

    /// Creates a fresh gate with no waiters.
    public init() {}

    /// Wake every current waiter; call right after mutating observed state.
    public func notify() {
        let resumes = waiters.withLock { waiters in
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        resumes.forEach { $0() }
    }

    /// Suspend until `predicate()` holds (re-checked on each `notify()`), or
    /// throw `TestFailure` after `timeout` seconds.
    ///
    /// Returns the moment the predicate holds, whichever step made it hold and
    /// whether or not this gate has fired — so the predicate names the state
    /// the caller acts on next, never an earlier step's. The first evaluation
    /// that returns `true` ends the wait and none follows it, so a predicate
    /// may take what it checks for in the same critical section.
    public func wait(
        timeout: TimeInterval = testWaitBackstop,
        isolation: isolated (any Actor)? = #isolation,
        fileID: String = #fileID, line: Int = #line,
        until predicate: () -> Bool
    ) async throws {
        let backstop = Backstop("AsyncGate.wait(until:)", timeout: timeout, fileID: fileID, line: line)
        while !predicate() {
            let id = UUID()
            defer { waiters.withLock { _ = $0.removeValue(forKey: id) } }
            // A notify may land before the waiter is registered, so the
            // predicate is checked again once it is.
            let heldAtArm: Bool = try await backstop.park(isolation: isolation) { resume in
                waiters.withLock { $0[id] = { resume(false) } }
                if predicate() { resume(true) }
            }
            if heldAtArm { return }
        }
    }
}

// MARK: - waitUntil

// `isolation` uses the Swift `isolated` keyword to inherit the caller's actor
// isolation, so it is never referenced by name.
// periphery:ignore:parameters isolation
/// Polls `predicate` every 50 ms until it returns `true`, or throws
/// `TestFailure` once `timeout` seconds pass first.
///
/// The deadline here *is* the pass/fail criterion — prefer `AsyncGate` for a new
/// timing-sensitive wait; polling is for predicates with no signal to await.
public func waitUntil(
    timeout: TimeInterval = testWaitBackstop,
    isolation: isolated (any Actor)? = #isolation,
    fileID: String = #fileID, line: Int = #line,
    _ predicate: () -> Bool
) async throws {
    let backstop = Backstop("waitUntil", timeout: timeout, fileID: fileID, line: line)
    while !predicate() {
        guard !backstop.expired else { throw backstop.failure() }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

// MARK: - awaitFirst

/// Awaits the first value `stream` emits that `predicate` accepts — any value
/// when none is given.
///
/// - Throws: ``Backstop/failure(_:)`` when none arrives by the
///   `testWaitBackstop` deadline.
/// - Throws: `TestFailure("Stream finished…")` when the stream ends first, so
///   the two failure shapes are identifiable.
public func awaitFirst<T: Sendable>(
    _ stream: AsyncStream<T>, fileID: String = #fileID, line: Int = #line,
    where predicate: @escaping @Sendable (T) -> Bool = { _ in true }
) async throws -> T {
    try await Backstop("awaitFirst", fileID: fileID, line: line).run {
        for await value in stream where predicate(value) { return value }
        throw TestFailure("Stream finished without producing a value")
    }
}

// MARK: - Main-queue ordering

/// Suspends until every block already queued on the main queue has run.
///
/// The main queue is serial, so a block enqueued now runs last: this is an
/// ordering barrier, not a wait — nothing is polled and no deadline decides it,
/// and the backstop fires only when a block ahead of it never returns.
/// Use it to assert on what already-queued work left behind, from a
/// `@MainActor` test body: `DispatchQueue.main.async` blocks, and main-actor
/// tasks — the main actor's executor is equivalent to the main dispatch queue
/// ([MainActor](https://developer.apple.com/documentation/swift/mainactor)).
public func drainMainQueue(fileID: String = #fileID, line: Int = #line) async throws {
    try await Backstop("drainMainQueue()", fileID: fileID, line: line).park { resume in
        DispatchQueue.main.async { resume(()) }
    }
}

// MARK: - BlockingInbox

/// Values a handler on another thread delivers, which a test reads in order,
/// blocking for each.
public final class BlockingInbox<Value: Sendable>: Sendable {
    private let values = Locked<[Value]>([])
    /// Signalled once per value put.
    private let arrived = DispatchSemaphore(value: 0)

    /// An inbox holding nothing.
    public init() {}

    /// Delivers `value`.
    public func put(_ value: Value) {
        values.withLock { $0.append(value) }
        arrived.signal()
    }

    /// Whether every value delivered so far has been read.
    public var isEmpty: Bool { values.withLock(\.isEmpty) }

    /// The oldest value not yet read, once one has arrived.
    @available(*, noasync, message: "Await a value through Backstop.park instead of blocking a cooperative thread")
    public func next(fileID: String = #fileID, line: Int = #line) throws(TestFailure) -> Value {
        try Backstop("BlockingInbox.next()", fileID: fileID, line: line).wait(for: arrived)
        return values.withLock { $0.removeFirst() }
    }

    /// The next `count` values, each waited for as ``next(fileID:line:)`` waits.
    @available(*, noasync, message: "Await values through Backstop.park instead of blocking a cooperative thread")
    public func next(_ count: Int, fileID: String = #fileID, line: Int = #line) throws(TestFailure) -> [Value] {
        var values: [Value] = []
        for _ in 0..<count { values.append(try next(fileID: fileID, line: line)) }
        return values
    }
}
