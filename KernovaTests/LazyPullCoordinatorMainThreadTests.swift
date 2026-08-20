import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The main-thread branch of `LazyPullCoordinator.pull` — the wait that runs the
/// application's event loop instead of parking. It needs a live `NSApplication`,
/// which only this app-hosted bundle has.
///
/// `.serialized` because `offThreadDeliverWakesPull` stretches
/// `NestedEventLoopWait.sliceSecondsForTesting`, which is process-wide: run
/// concurrently, it hands `nestedWaitsBothResolve` a 5 s re-check slice, and a
/// 5 s slice is exactly the stranding that test asserts against. Observed
/// 2026-08-20 (run 32341761480): all four cases reported the same 15.58 s and
/// two of them failed.
@Suite("LazyPullCoordinator on the main thread", .serialized, .admissionGated)
@MainActor
struct LazyPullCoordinatorMainThreadTests {
    // RATIONALE: 5 s, far below `testWaitBackstop`. Each test holds the real
    // main thread inside `pull` from this main-queue job, where the nested loop
    // cannot drain the main queue (docs/TESTING.md), so the window caps how long
    // the bundle's MainActor is held hostage if the fast path loses; every fast
    // path here is ms-scale and same-thread, so the value never masks a failure.
    private static let window: TimeInterval = 5

    private nonisolated func inlineRep(_ text: String) -> ClipboardContent.Representation {
        ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data(text.utf8))
    }

    @Test("a main-thread pull keeps the run loop turning: a block performed on it resolves the pull")
    func performedMainRunLoopBlockResolvesPull() {
        let coordinator = LazyPullCoordinator()
        let rep = inlineRep("live")
        // Scheduled before the pull. A parked wait could only run it after
        // returning — timed out — so `.delivered` proves the loop turned.
        RunLoop.main.perform { coordinator.deliver(7, rep) }

        let outcome = coordinator.pull(transferID: 7, timeout: Self.window, retire: {}, start: {})

        guard case .delivered(let delivered) = outcome else {
            Issue.record("Expected .delivered from the performed block, got \(outcome)")
            return
        }
        #expect(delivered.inMemoryData == Data("live".utf8))
    }

    @Test("failAll performed on the main run loop cancels a main-thread pull")
    func performedFailAllCancelsPull() {
        let coordinator = LazyPullCoordinator()
        RunLoop.main.perform { coordinator.failAll() }

        let outcome = coordinator.pull(transferID: 8, timeout: Self.window, retire: {}, start: {})

        guard case .cancelled = outcome else {
            Issue.record("Expected .cancelled from the performed failAll, got \(outcome)")
            return
        }
    }

    @Test("nested main-thread waits both resolve, and the outer is not stranded by the inner (#860)")
    func nestedWaitsBothResolve() {
        let coordinator = LazyPullCoordinator()
        let innerResolved = Box(false)
        let clock = ContinuousClock()
        let started = clock.now

        // The outer pull runs the event loop. From inside it, a nested inner pull
        // for a different id runs its own loop while the outer is resolved. The
        // wait's wake events are not addressed to a specific loop, so the inner
        // can consume the outer's; the outer must still return promptly rather
        // than stranding to its window — the per-slice re-check is what guarantees
        // that under any interleaving.
        let outcome = coordinator.pull(transferID: 1, timeout: 5, retire: {}) {
            RunLoop.main.perform {
                let inner = coordinator.pull(transferID: 2, timeout: 5, retire: {}) {
                    coordinator.deliver(1, self.inlineRep("outer"))
                    RunLoop.main.perform { coordinator.deliver(2, self.inlineRep("inner")) }
                }
                if case .delivered(let rep) = inner, rep.inMemoryData == Data("inner".utf8) {
                    innerResolved.value = true
                }
            }
        }

        guard case .delivered(let rep) = outcome else {
            Issue.record("Expected the outer pull to deliver, got \(outcome)")
            return
        }
        #expect(rep.inMemoryData == Data("outer".utf8))
        #expect(innerResolved.value)
        // Both resolved rather than blocking to the 5 s window. The bound sits
        // just under it: stranding takes the whole window, the per-slice
        // re-check returns in ~0.1 s, and every second between the two is
        // jitter tolerance rather than a sharper assertion.
        #expect(clock.now - started < .seconds(4))
    }

    @Test("a resolve from another thread breaks the wait at once, not at the next slice")
    func offThreadDeliverWakesPull() {
        let coordinator = LazyPullCoordinator()
        let rep = inlineRep("woken")
        let clock = ContinuousClock()
        // Stretch the re-check slice to the whole window: without the wake the
        // loop still returns `.delivered`, but only once a slice elapses, so the
        // duration is the assertion — the deadline itself (docs/TESTING.md), and
        // the 4 s bound leaves the ms-scale wake room under scheduling jitter.
        NestedEventLoopWait.sliceSecondsForTesting = Self.window
        defer { NestedEventLoopWait.sliceSecondsForTesting = nil }

        // The delivering thread is created and scheduled *before* the clock
        // starts: spawning a thread is the jitter-prone part of this, and inside
        // the measured window a starved runner's thread-creation latency is
        // timed as if it were wake latency. It parks on `release` — a semaphore,
        // so the signal cannot be missed however the two are ordered — and the
        // pull's `start:` closure below opens it once the slot is registered.
        let running = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        Thread {
            running.signal()
            release.wait()
            coordinator.deliver(9, rep)
        }.start()
        #expect(running.wait(timeout: .now() + Self.window) == .success)

        let started = clock.now
        let outcome = coordinator.pull(transferID: 9, timeout: Self.window, retire: {}) {
            // Runs on this thread once the slot is registered, so the deliver
            // it releases cannot be missed.
            release.signal()
        }

        guard case .delivered(let delivered) = outcome else {
            Issue.record("Expected .delivered from the other thread, got \(outcome)")
            return
        }
        #expect(delivered.inMemoryData == Data("woken".utf8))
        #expect(clock.now - started < .seconds(4))
    }
}
