import Foundation
import os

// MARK: - TestAdmissionGate

/// FIFO counting semaphore bounding how many holders run at once.
///
/// `acquire()` suspends when every permit is out and resumes waiters in arrival
/// order; `release()` hands the permit to the oldest waiter, or returns it to
/// the pool when nobody is queued. A queued caller costs one suspended task and
/// nothing else — no thread, no timer.
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
/// The width is read once, from the first source below that parses to a
/// non-negative integer. Zero — and no source at all — means pass-through, so
/// the same binary serves both arms of an A/B measurement.
public enum TestAdmission {
    private static let logger = Logger(subsystem: "app.kernova", category: "TestAdmission")

    /// Environment variable naming the width. `xcodebuild` strips the
    /// `TEST_RUNNER_` prefix from host variables when it launches the test
    /// runner, so both spellings are read.
    private static let environmentKey = "KERNOVA_TEST_ADMISSION_WIDTH"

    /// File naming the width, for hosts that receive no environment at all. The
    /// sandboxed test host resolves `NSHomeDirectory()` to its container, which
    /// is the only one of these two paths it can read.
    private static let fileName = "kernova-test-admission-width"

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
    /// names the arm a CI run actually took.
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
    /// reports so a CI run shows which mechanism actually delivered the value.
    private static func candidates() -> [(String, String?)] {
        let environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory() + "/" + fileName
        let temporary = "/tmp/" + fileName
        return [
            ("env \(environmentKey)", environment[environmentKey]),
            ("env TEST_RUNNER_\(environmentKey)", environment["TEST_RUNNER_" + environmentKey]),
            ("file \(home)", try? String(contentsOfFile: home, encoding: .utf8)),
            ("file \(temporary)", try? String(contentsOfFile: temporary, encoding: .utf8)),
        ]
    }
}
