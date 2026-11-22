import Foundation
import KernovaSynchronization

// MARK: - Blocking calls

/// A **synchronous, blocking** call — a bridge call parked until its transfer
/// resolves, as production's callers make it — started at once on a thread of
/// its own.
///
/// A blocked call holds its thread, so held on a pool's thread enough of them
/// exhaust the pool and starve the work their replies depend on: the
/// cooperative pool has a few threads (3-4 on CI; observed as the 2026-07-19
/// CI mass failures), and GCD's global queues share 64
/// (`kern.wq_max_constrained_threads`).
public final class BlockingCall<T: Sendable>: Sendable {
    private enum State: Sendable {
        case running(waiting: [@Sendable (T) -> Void])
        case returned(T)
    }

    private let state = Locked(State.running(waiting: []))

    /// Starts `body`.
    public init(_ body: @escaping @Sendable () -> T) {
        let state = state
        Thread {
            let value = body()
            let waiting = state.withLock { state in
                defer { state = .returned(value) }
                guard case .running(let waiting) = state else { return [@Sendable (T) -> Void]() }
                return waiting
            }
            for resume in waiting { resume(value) }
        }.start()
    }

    /// What the call returned, once it has; throws `Backstop.failure(_:)` when
    /// it is still blocked at the deadline, leaving it to return to nothing.
    public func returned(fileID: String = #fileID, line: Int = #line) async throws -> T {
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
    try await BlockingCall(body).returned(fileID: fileID, line: line)
}

// MARK: - Task joins

extension Task {
    /// The task's value, once it has ended; throws `Backstop.failure(_:)`
    /// when it is still running at the deadline, leaving it to run on.
    ///
    /// A join parks until the task ends, and the task may itself wait on
    /// anything, so a test joins a task through this rather than `value`.
    public func joined(fileID: String = #fileID, line: Int = #line) async throws -> Success {
        try await joinedResult(fileID: fileID, line: line).get()
    }

    /// The task's result, once it has ended, waited for as
    /// ``joined(fileID:line:)`` waits.
    public func joinedResult(fileID: String = #fileID, line: Int = #line) async throws -> Result<Success, Failure> {
        try await Backstop("the joined task", fileID: fileID, line: line).run { await self.result }
    }
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
    ///
    /// The backstop's failure names the wait `name`.
    public func wait(
        named name: String = "AsyncGate.wait(until:)",
        timeout: TimeInterval = testWaitBackstop,
        isolation: isolated (any Actor)? = #isolation,
        fileID: String = #fileID, line: Int = #line,
        until predicate: () -> Bool
    ) async throws {
        if predicate() { return }
        let backstop = Backstop(name, timeout: timeout, fileID: fileID, line: line)
        let id = UUID()
        defer { waiters.withLock { _ = $0.removeValue(forKey: id) } }
        while true {
            // A notify may land before the waiter is registered, so the
            // predicate is checked again once it is — and what that check
            // answers decides, whether or not a notify has resumed the park.
            var holds = false
            try await backstop.park(isolation: isolation) { (resume: @escaping @Sendable (()) -> Void) in
                waiters.withLock { $0[id] = { resume(()) } }
                holds = predicate()
                if holds { resume(()) }
            }
            if holds { return }
        }
    }

    /// Blocks the calling thread until `predicate()` holds, as
    /// ``wait(named:timeout:isolation:fileID:line:until:)`` suspends.
    @available(*, noasync, message: "Await wait(until:) instead of blocking a cooperative thread")
    public func block(
        named name: String = "AsyncGate.block(until:)",
        timeout: TimeInterval = testWaitBackstop, fileID: String = #fileID, line: Int = #line,
        until predicate: () -> Bool
    ) throws(TestFailure) {
        if predicate() { return }
        let backstop = Backstop(name, timeout: timeout, fileID: fileID, line: line)
        let notified = DispatchSemaphore(value: 0)
        let id = UUID()
        defer { waiters.withLock { _ = $0.removeValue(forKey: id) } }
        while true {
            waiters.withLock { $0[id] = { notified.signal() } }
            if predicate() { return }
            try backstop.wait(for: notified)
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
/// waiting for each: a test body awaits them, and a thread of its own — a
/// handler holding the code under test — blocks for them.
public final class BlockingInbox<Value: Sendable>: Sendable {
    private let values = Locked<[Value]>([])
    private let arrived = AsyncGate()

    /// An inbox holding nothing.
    public init() {}

    /// Delivers `value`.
    public func put(_ value: Value) {
        values.withLock { $0.append(value) }
        arrived.notify()
    }

    /// Whether every value delivered so far has been read.
    public var isEmpty: Bool { values.withLock(\.isEmpty) }

    /// The oldest value not yet read, once one has arrived.
    public func next(fileID: String = #fileID, line: Int = #line) async throws -> Value {
        var taken: Value?
        try await arrived.wait(named: "BlockingInbox.next()", fileID: fileID, line: line) {
            taken = take()
            return taken != nil
        }
        return Self.taken(taken)
    }

    /// The next `count` values, each waited for as ``next(fileID:line:)`` waits.
    public func next(_ count: Int, fileID: String = #fileID, line: Int = #line) async throws -> [Value] {
        var values: [Value] = []
        for _ in 0..<count { values.append(try await next(fileID: fileID, line: line)) }
        return values
    }

    /// The oldest value not yet read, once one has arrived, blocking the
    /// calling thread as ``next(fileID:line:)`` suspends.
    @available(*, noasync, message: "Await next(fileID:line:) instead of blocking a cooperative thread")
    public func next(fileID: String = #fileID, line: Int = #line) throws(TestFailure) -> Value {
        var taken: Value?
        try arrived.block(named: "BlockingInbox.next()", fileID: fileID, line: line) {
            taken = take()
            return taken != nil
        }
        return Self.taken(taken)
    }

    /// Removes and answers the oldest value, if any.
    private func take() -> Value? {
        values.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    /// What a gate wait's predicate took: the gate returns only once the
    /// predicate held, so a value is always there.
    private static func taken(_ taken: Value?) -> Value {
        guard let taken else { preconditionFailure("the inbox's gate returned before a value was taken") }
        return taken
    }
}
