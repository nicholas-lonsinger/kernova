import Darwin
import Foundation
import KernovaKit

// MARK: - testWaitBackstop

/// Default stuck-condition backstop for every test wait helper, in seconds.
///
/// Sized past any plausible CI scheduler stall — starved macos-26 runners have
/// defeated 5 s and 10 s backstops. Success-path waits must not pass a smaller
/// explicit timeout; explicit values are for behavior-under-test deadlines only
/// (docs/TESTING.md, "Async waits in tests").
public let testWaitBackstop: TimeInterval = 60

// MARK: - Test-session OS activity

/// OS activity exempting the test host from App Nap and idle timer throttling,
/// begun by the first `armTestSessionActivity()` call — which reads this token
/// precisely to run the lazy initializer — and held for the rest of the
/// process's life. `.userInitiated` also deliberately keeps the machine from
/// idle-sleeping mid-run: system sleep would blow every armed backstop.
///
/// On an idle, display-off machine the OS can hold a windowless process's
/// timers past the 60 s backstop, then release every armed wait at one
/// instant, mass-failing whatever cases are in flight (observed 2026-08-06,
/// #759). Test runs are user-initiated work even when the display is off.
nonisolated(unsafe) private let testSessionActivity: NSObjectProtocol =
    ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "Test waits measure real time and must not be throttled")

/// Begins the test session's OS activity on first call; later calls no-op.
///
/// `BackstopStopwatch.init` calls this, covering every wait built on the
/// shared helpers; a wait that bypasses them (a raw semaphore backstop) calls
/// it directly before parking.
public func armTestSessionActivity() {
    _ = testSessionActivity
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

// MARK: - BackstopStopwatch

/// Captures both timelines at wait start so a fired backstop can self-diagnose.
///
/// Creating one also arms the test session's OS activity. Every shared wait
/// helper starts one and throws `TestFailure.backstop` at its deadline.
public struct BackstopStopwatch: Sendable {
    private let clock = MonotonicEngineClock()
    private let start: EngineInstant
    private let uptimeStartNanoseconds: UInt64

    /// Reads both clocks, arming the session activity as a side effect.
    public init() {
        armTestSessionActivity()
        start = clock.now
        uptimeStartNanoseconds = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// Seconds of continuous time since creation.
    public var elapsed: TimeInterval { clock.seconds(since: start) }

    /// The parenthetical a fired backstop appends to its failure message, from
    /// readings taken at the call — empty when `elapsed` never reached
    /// `timeout` (a predicate that flapped, not a fired backstop).
    func diagnosis(timeout: TimeInterval) -> String {
        let uptimeElapsed =
            Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - uptimeStartNanoseconds)
            / 1_000_000_000
        return backstopDiagnosis(
            timeout: timeout, continuousElapsed: elapsed, uptimeElapsed: uptimeElapsed)
    }
}

extension TestFailure {
    /// A fired-backstop failure with the stopwatch's self-diagnosis appended.
    ///
    /// Every deadline throw goes through here so no wait seam ships a bare
    /// timeout message without the timing numbers.
    public static func backstop(
        _ message: String, stopwatch: BackstopStopwatch, timeout: TimeInterval
    ) -> TestFailure {
        sampleProcessOnceForDiagnosis()
        return TestFailure(message + stopwatch.diagnosis(timeout: timeout))
    }

    /// `backstop(_:stopwatch:timeout:)` for the `Duration`-based wait helpers.
    @available(macOS 13.0, *)
    public static func backstop(
        _ message: String, stopwatch: BackstopStopwatch, timeout: Duration
    ) -> TestFailure {
        let seconds =
            Double(timeout.components.seconds) + Double(timeout.components.attoseconds) * 1e-18
        return backstop(message, stopwatch: stopwatch, timeout: seconds)
    }
}

/// Renders `BackstopStopwatch.diagnosis(timeout:)`: how far past its deadline
/// the backstop fired (continuous time) and how much of the wait the system
/// spent asleep (continuous minus uptime elapsed), with a machine-state hint
/// once either exceeds honest-scheduling bounds.
func backstopDiagnosis(
    timeout: TimeInterval, continuousElapsed: TimeInterval, uptimeElapsed: TimeInterval
) -> String {
    guard continuousElapsed >= timeout else { return "" }
    let late = continuousElapsed - timeout
    let slept = max(0, continuousElapsed - uptimeElapsed)
    var text = String(
        format: " (backstop fired %.2f s past its deadline; the system slept %.2f s of the wait",
        late, slept)
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

// MARK: - ResumeOnce

/// Resumes its continuation at most once, regardless of how many racing paths
/// (a `notify()` and the timeout backstop) try to fire it.
///
/// `CheckedContinuation` traps on a second resume.
public final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Creates a fresh, unfired guard.
    public init() {}

    /// Runs `body` only on the first call; every later call is a no-op.
    public func fire(_ body: () -> Void) {
        lock.lock()
        let already = fired
        fired = true
        lock.unlock()
        if !already { body() }
    }
}

// MARK: - AsyncGate

/// Event-driven replacement for a `waitUntil` poll loop.
///
/// A producer calls `notify()` after each observable state change; the consumer
/// awaits `wait(until:)`, which suspends until the predicate holds — re-checked
/// on every `notify()` — or throws `TestFailure` after `timeout`, a
/// stuck-condition backstop the happy path never reaches.
public final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: () -> Void] = [:]

    /// Creates a fresh gate with no waiters.
    public init() {}

    /// Wake every current waiter; call right after mutating observed state.
    public func notify() {
        lock.lock()
        let resumes = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        resumes.forEach { $0() }
    }

    /// Suspend until `predicate()` holds (re-checked on each `notify()`), or
    /// throw `TestFailure` after `timeout` seconds.
    public func wait(
        timeout: TimeInterval = testWaitBackstop,
        isolation: isolated (any Actor)? = #isolation,
        until predicate: () -> Bool
    ) async throws {
        let stopwatch = BackstopStopwatch()
        while !predicate() {
            if stopwatch.elapsed >= timeout {
                throw TestFailure.backstop(
                    "Condition not met within \(timeout) s",
                    stopwatch: stopwatch, timeout: timeout)
            }
            await armOnce(
                stopwatch: stopwatch, timeout: timeout,
                isolation: isolation, predicate: predicate)
        }
    }

    /// Suspends until the next `notify()`, an immediate hit (the predicate
    /// already holds at arm time, closing the arm-vs-notify race), or the
    /// deadline backstop (`timeout` after the stopwatch's start) — whichever
    /// comes first.
    // `isolation` uses the Swift `isolated` keyword to pin this helper to the
    // caller's actor, so it is intentionally never referenced by name.
    // periphery:ignore:parameters isolation
    private func armOnce(
        stopwatch: BackstopStopwatch,
        timeout: TimeInterval,
        isolation: isolated (any Actor)?,
        predicate: () -> Bool
    ) async {
        // Cancelled once the wait resolves, so a happy-path arm doesn't leak a
        // Task sleeping until `deadline`.
        var backstop: Task<Void, Never>?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let id = UUID()
            let once = ResumeOnce()
            lock.lock()
            waiters[id] = { once.fire { cont.resume() } }
            lock.unlock()
            // Close the arm-vs-notify race: a notify may have landed before we
            // registered, so re-check now instead of blocking.
            if predicate() {
                lock.lock()
                waiters.removeValue(forKey: id)
                lock.unlock()
                once.fire { cont.resume() }
                return
            }
            // Resume at the deadline even if no notify arrives, so a stuck
            // condition fails the wait instead of hanging.
            backstop = Task {
                try? await MonotonicEngineClock().sleep(for: max(0, timeout - stopwatch.elapsed))
                self.lock.withLock { self.waiters[id] = nil }
                once.fire { cont.resume() }
            }
        }
        backstop?.cancel()
    }
}

// MARK: - waitUntil

// `isolation` uses the Swift `isolated` keyword to inherit the caller's actor
// isolation, so it is intentionally never referenced by name.
// periphery:ignore:parameters isolation
/// Polls `predicate` every 50 ms until it returns `true` or `timeout` seconds
/// elapse.
///
/// The deadline here *is* the pass/fail criterion — prefer `AsyncGate` for a new
/// timing-sensitive wait; polling is for predicates with no signal to await.
public func waitUntil(
    timeout: TimeInterval = testWaitBackstop,
    isolation: isolated (any Actor)? = #isolation,
    _ predicate: () -> Bool
) async throws {
    let stopwatch = BackstopStopwatch()
    while !predicate() && stopwatch.elapsed < timeout {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard predicate() else {
        throw TestFailure.backstop(
            "Predicate did not become true within \(timeout) s",
            stopwatch: stopwatch, timeout: timeout)
    }
}

// MARK: - offCooperativePool

/// Runs a **synchronous, blocking** bridge call on a GCD global-queue thread,
/// mirroring production's callers.
///
/// RATIONALE: a blocking bridge call parks its thread until the transfer
/// resolves, so it belongs on a GCD global queue — those overcommit, and a
/// parked pull there costs a kernel thread rather than one of the cooperative
/// pool's 3-4 CI threads. Parked on the cooperative pool instead, enough pulls
/// exhaust it, the tasks the reply depends on starve, and the bundle freezes
/// until the shortest injected timeout fires — the 2026-07-19 CI mass failures
/// (#608), #618 for the guest bundle. See docs/TESTING.md "Blocking bridge calls
/// run on GCD".
public func offCooperativePool<T: Sendable>(
    _ body: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: body()) }
    }
}

// DIAGNOSTIC (scratch branch only): sample this process's threads the first
// time any backstop fires, so a CI-only stall shows where every thread sits.
nonisolated(unsafe) private var didSampleForDiagnosis = false
private let sampleLock = NSLock()
private func sampleProcessOnceForDiagnosis() {
    let first = sampleLock.withLock { () -> Bool in
        if didSampleForDiagnosis { return false }
        didSampleForDiagnosis = true
        return true
    }
    guard first else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "1", "-mayDie"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data.prefix(400_000), as: UTF8.self)
        FileHandle.standardError.write(
            Data("\n===== DIAG SAMPLE BEGIN pid=\(ProcessInfo.processInfo.processIdentifier) =====\n".utf8))
        FileHandle.standardError.write(Data(text.utf8))
        FileHandle.standardError.write(Data("\n===== DIAG SAMPLE END =====\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("DIAG SAMPLE FAILED: \(error)\n".utf8))
    }
}
