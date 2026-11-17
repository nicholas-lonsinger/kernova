import CKernovaShims
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
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

/// A test failure with a diagnostic message, thrown by the wait helpers.
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
    private let uptimeStart = uptimeNanoseconds()

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
        let uptimeElapsed = Self.seconds(uptimeNanoseconds() &- uptimeStart)
        return TestFailure(
            "\(wait) did not end within \(timeout) s" + (detail.map { ": " + $0 } ?? "")
                + backstopDiagnosis(timeout: timeout, continuousElapsed: elapsed, uptimeElapsed: uptimeElapsed))
    }

    // `isolation` uses the Swift `isolated` keyword to run `start` in the
    // caller's isolation, so it is never referenced by name.
    // periphery:ignore:parameters isolation
    /// Suspends until `start`'s `resume` runs, answering the value it was
    /// given; throws ``failure(_:)`` once the deadline passes first.
    ///
    /// `start` runs at once, in the caller's isolation, and hands `resume` to
    /// whatever will answer: a completion handler, a queue, a list of waiters.
    /// `resume` may run on any thread, before `start` returns included. Only
    /// its first call counts, and a call after the wait has ended changes
    /// nothing, so what the wait gave up on may still make it.
    ///
    /// Cancelling the waiting task does not end the wait: a double that holds
    /// the code under test until the test releases it parks here too, and
    /// holds through a cancel the way the work it stands in for would.
    public func park<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ start: (_ resume: @escaping @Sendable (T) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let parked = Parked(continuation)
            start { parked.settle(.success($0)) }
            parked.arm(self)
        }
    }

    /// Runs `operation` in a task of its own, answering what it returns or
    /// rethrowing what it throws; throws ``failure(_:)`` once the deadline
    /// passes first.
    ///
    /// At the deadline the operation is cancelled and left to stop in its own
    /// time, so this returns even when the operation ignores cancellation.
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

    /// The longest a dispatch wait may run before the continuous clock is
    /// read again: `remaining`, but no more than a second.
    fileprivate static func slice(_ remaining: TimeInterval) -> TimeInterval { min(max(remaining, 0), 1) }

    fileprivate static func seconds(_ nanoseconds: UInt64) -> TimeInterval {
        TimeInterval(nanoseconds) / 1_000_000_000
    }
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

/// Nanoseconds on a monotonic clock that stops while the machine sleeps —
/// Darwin `CLOCK_UPTIME_RAW`, Linux `CLOCK_MONOTONIC`, Windows
/// `QueryUnbiasedInterruptTime` — set against `kernova_monotonic_nanoseconds`,
/// which keeps counting, to tell how much of a wait the machine slept.
private func uptimeNanoseconds() -> UInt64 {
    #if canImport(Darwin)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    #elseif canImport(WinSDK)
    var hundreds: ULONGLONG = 0
    _ = QueryUnbiasedInterruptTime(&hundreds)
    return UInt64(hundreds) * 100
    #else
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec)
    #endif
}

/// `seconds` with two decimal places.
private func hundredths(_ seconds: TimeInterval) -> String {
    let hundredths = Int((seconds * 100).rounded())
    let fraction = String(hundredths % 100)
    return "\(hundredths / 100)." + String(repeating: "0", count: 2 - fraction.count) + fraction
}

/// One park's outcome, settled once: by what `start` handed `resume` to, or by
/// the deadline, whichever comes first.
private final class Parked<T: Sendable>: Sendable {
    private struct State: Sendable {
        /// The parked wait, until it is settled.
        var continuation: CheckedContinuation<T, any Error>?
        /// The deadline's entry in the expiry watch, once armed and until settled.
        var expiry: ExpiryWatch.Entry?
    }

    private let state: Locked<State>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        state = Locked(State(continuation: continuation))
    }

    /// Settles with `backstop`'s failure once it expires, unless something
    /// settles first.
    func arm(_ backstop: Backstop) {
        let expiry = ExpiryWatch.shared.arm(backstop) { [self] in settle(.failure(backstop.failure())) }
        let armed = state.withLock { state in
            guard state.continuation != nil else { return false }
            state.expiry = expiry
            return true
        }
        if !armed { ExpiryWatch.shared.disarm(expiry) }
    }

    /// Settles with `outcome` unless already settled.
    func settle(_ outcome: Result<T, any Error>) {
        let (continuation, expiry) = state.withLock { state in
            defer { (state.continuation, state.expiry) = (nil, nil) }
            return (state.continuation, state.expiry)
        }
        if let expiry { ExpiryWatch.shared.disarm(expiry) }
        continuation?.resume(with: outcome)
    }
}

/// The one thread that ends every park whose deadline has passed.
///
/// A thread of its own, rather than a timer on a dispatch queue or a task: the
/// work a test waits on may block every thread a pool has — the cooperative
/// pool's few, or the 64 that GCD's global queues share
/// (`kern.wq_max_constrained_threads`) — and a deadline that needs one of
/// those threads to fire never fires.
private final class ExpiryWatch: Sendable {
    static let shared = ExpiryWatch()

    /// A park's place in the watch.
    struct Entry: Hashable, Sendable {
        fileprivate let key: UInt64
    }

    private struct Armed: Sendable {
        let backstop: Backstop
        let expire: @Sendable () -> Void
    }

    private struct State: Sendable {
        var armed: [Entry: Armed] = [:]
        var nextKey: UInt64 = 0
        /// When, on the continuous clock, the watch next reads the armed deadlines.
        var nextRead: UInt64 = .max
    }

    private let state = Locked(State())
    /// Signalled when a deadline is armed sooner than the watch's next read.
    private let sooner = DispatchSemaphore(value: 0)

    private init() {
        let thread = Thread { [self] in watch() }
        thread.name = "Backstop expiry watch"
        thread.start()
    }

    /// Calls `expire` on the watch's thread once `backstop` has expired,
    /// unless the entry is disarmed first.
    func arm(_ backstop: Backstop, _ expire: @escaping @Sendable () -> Void) -> Entry {
        let read = kernova_monotonic_nanoseconds() &+ Self.nanoseconds(Backstop.slice(backstop.remaining))
        let (entry, isSooner) = state.withLock { state in
            let entry = Entry(key: state.nextKey)
            state.nextKey += 1
            state.armed[entry] = Armed(backstop: backstop, expire: expire)
            guard read < state.nextRead else { return (entry, false) }
            state.nextRead = read
            return (entry, true)
        }
        if isSooner { sooner.signal() }
        return entry
    }

    /// Removes `entry`, so its `expire` is not called if it has not been.
    func disarm(_ entry: Entry) {
        state.withLock { _ = $0.armed.removeValue(forKey: entry) }
    }

    /// Reads the armed deadlines at least once a second — dispatch's timed
    /// wait runs on a clock that stops while the machine sleeps — calling
    /// each expired one's `expire` outside the lock.
    private func watch() {
        while true {
            let (expired, wait) = state.withLock { state in
                var expired: [@Sendable () -> Void] = []
                var wait: TimeInterval = 1
                for (entry, armed) in state.armed {
                    let remaining = armed.backstop.remaining
                    if remaining <= 0 {
                        expired.append(armed.expire)
                        state.armed[entry] = nil
                    } else {
                        wait = min(wait, remaining)
                    }
                }
                state.nextRead = kernova_monotonic_nanoseconds() &+ Self.nanoseconds(wait)
                return (expired, wait)
            }
            for expire in expired { expire() }
            _ = sooner.wait(timeout: .now() + wait)
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(seconds * 1_000_000_000) }
}
