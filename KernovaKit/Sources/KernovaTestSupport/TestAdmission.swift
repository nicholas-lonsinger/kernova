import Foundation
import os

// MARK: - TestAdmissionGate

/// FIFO counting semaphore bounding how many holders run at once.
///
/// `acquire()` suspends when every permit is out and resumes waiters in arrival
/// order; `release()` hands the permit to the oldest waiter, or returns it to
/// the pool when nobody is queued. A queued caller costs one suspended task and
/// nothing else — no thread, no timer.
///
/// **A queued waiter is not removed when its task is cancelled.** The handoff in
/// `release()` transfers the permit itself rather than a count, so a waiter
/// resumed out of band would either run without a permit or, if the count were
/// bumped to compensate, inflate the pool. Leaving a cancelled waiter in the
/// queue costs it one turn's wait and keeps the invariant exact; cancellation is
/// then observed by the work it wraps.
public final class TestAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int
    private var waiters: [() -> Void] = []

    /// Creates a gate holding `width` permits; a width below 1 admits nobody.
    public init(width: Int) {
        available = max(0, width)
    }

    /// Suspends until a permit is free, then takes it.
    public func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard available > 0 else {
                waiters.append { continuation.resume() }
                lock.unlock()
                return
            }
            available -= 1
            lock.unlock()
            continuation.resume()
        }
    }

    /// Returns a permit, resuming the oldest waiter if one is queued.
    public func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            available += 1
            lock.unlock()
            return
        }
        let resume = waiters.removeFirst()
        lock.unlock()
        resume()
    }

    #if DEBUG
    /// Permits not currently held, for a test asserting the pool stays balanced.
    var availableForTesting: Int { lock.withLock { available } }

    /// Callers queued for a permit.
    var waiterCountForTesting: Int { lock.withLock { waiters.count } }
    #endif
}

// MARK: - TestAdmission

/// The process-wide admission gate every test case passes through.
///
/// Swift Testing starts every test as a task immediately, so a bundle's whole
/// suite is in flight at once, contending for the `@MainActor` while sharing
/// one wall-clock `testWaitBackstop`. Gating admission bounds that in-flight
/// set; the tests beyond it stay suspended *before* their setup runs, so no
/// clock is armed while they queue.
///
/// **The bound is per process, which is the granularity the contention has.**
/// `xcodebuild` runs a parallelizable target as several test-host clones, and
/// each clone is its own process with its own main thread, so machine-wide
/// concurrency is this width times the clone count. That is deliberate: what a
/// test waits on is *its own* process's main actor, and bounding per process is
/// what relieves it. A width chosen for one runner's core count therefore does
/// not transfer to a runner with a different one, and a width at or above a
/// clone's own case count is indistinguishable from pass-through.
///
/// The width is read once, from the first source below that parses to a
/// non-negative integer. Zero — and no source at all — means pass-through, so
/// the same binary serves both arms of a measurement.
public enum TestAdmission {
    private static let logger = Logger(subsystem: "app.kernova", category: "TestAdmission")

    /// Environment variable naming the width. `xcodebuild` forwards only
    /// `TEST_RUNNER_`-prefixed variables from its own environment into the test
    /// runner, stripping the prefix — so a CI host must set
    /// `TEST_RUNNER_KERNOVA_TEST_ADMISSION_WIDTH`, and the plain spelling set
    /// there reaches nothing (observed 2026-08-20). The prefixed name is read
    /// here too, for a runner that forwards it verbatim.
    private static let environmentKey = "KERNOVA_TEST_ADMISSION_WIDTH"

    /// Marks a task that already holds a permit, so a trait applied at more than
    /// one level in a suite hierarchy admits once rather than once per level.
    /// Without it a case inheriting the trait from a suite *and* its nested
    /// suite would wait for a second permit while holding the first, deadlocking
    /// at any width below the number of such cases in flight.
    @TaskLocal public static var isAdmitted = false

    /// Concurrent test cases admitted per process; 0 disables gating entirely.
    public static let width: Int = resolveWidth()

    /// The shared gate, sized by ``width``.
    private static let gate = TestAdmissionGate(width: width)

    /// Suspends until this test case is admitted; a no-op when gating is off.
    public static func admit() async {
        guard width > 0 else { return }
        await gate.acquire()
    }

    /// Returns this test case's permit; a no-op when gating is off.
    public static func relinquish() {
        guard width > 0 else { return }
        gate.release()
    }

    /// Resolves the width and logs the outcome exactly once — this runs inside
    /// the lazy initializer of ``width``, so the log line marks first use and
    /// names the arm a run actually took.
    private static func resolveWidth() -> Int {
        for (source, raw) in candidates() {
            guard let raw else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(text), value >= 0 else { continue }
            let summary = "\(value > 0 ? "gating" : "pass-through") width \(value) from \(source)"
            logger.notice("Test admission \(summary, privacy: .public)")
            return value
        }
        logger.notice("Test admission pass-through: no width source")
        return 0
    }

    /// Width sources in priority order, each paired with the label the log line
    /// reports so a run shows which mechanism actually delivered the value.
    ///
    /// The environment is the only source. A dropped width *file* was tried and
    /// removed: `NSHomeDirectory()` is the container only for the sandboxed
    /// app-hosted bundle, so for the two unsandboxed ones it resolves to the
    /// developer's real home, where a leftover file would silently gate every
    /// later local run — the same failure the world-writable `/tmp` entry was
    /// dropped for.
    private static func candidates() -> [(String, String?)] {
        let environment = ProcessInfo.processInfo.environment
        return [
            ("env \(environmentKey)", environment[environmentKey]),
            ("env TEST_RUNNER_\(environmentKey)", environment["TEST_RUNNER_" + environmentKey]),
        ]
    }
}
