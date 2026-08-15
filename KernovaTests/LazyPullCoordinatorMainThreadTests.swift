import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

/// The main-thread branch of `LazyPullCoordinator.pull` — the wait that runs the
/// application's event loop instead of parking. It needs a live `NSApplication`,
/// which only this app-hosted bundle has.
@Suite("LazyPullCoordinator on the main thread")
@MainActor
struct LazyPullCoordinatorMainThreadTests {
    // RATIONALE: 5 s, far below `testWaitBackstop`. Each test holds the real
    // main thread inside `pull` from this main-queue job, where the nested loop
    // cannot drain the main queue (docs/TESTING.md), so the window caps how long
    // the bundle's MainActor is held hostage if the fast path loses; every fast
    // path here is ms-scale and same-thread, so the value never masks a failure.
    private static let window: TimeInterval = 5

    private func inlineRep(_ text: String) -> ClipboardContent.Representation {
        ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data(text.utf8))
    }

    @Test("a main-thread pull keeps the run loop turning: a block performed on it resolves the pull")
    func performedMainRunLoopBlockResolvesPull() {
        let coordinator = LazyPullCoordinator()
        let rep = inlineRep("live")
        // Scheduled before the pull. A parked wait could only run it after
        // returning — timed out — so `.delivered` proves the loop turned.
        RunLoop.main.perform { coordinator.deliver(7, rep) }

        let outcome = coordinator.pull(transferID: 7, timeout: Self.window) {}

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

        let outcome = coordinator.pull(transferID: 8, timeout: Self.window) {}

        guard case .cancelled = outcome else {
            Issue.record("Expected .cancelled from the performed failAll, got \(outcome)")
            return
        }
    }

    @Test("a resolve from another thread breaks the wait at once, not at the window boundary")
    func offThreadDeliverWakesPull() {
        let coordinator = LazyPullCoordinator()
        let rep = inlineRep("woken")
        let clock = ContinuousClock()
        let started = clock.now

        let outcome = coordinator.pull(transferID: 9, timeout: Self.window) {
            // Runs on this thread once the slot is registered, so the deliver
            // below cannot be missed.
            Thread { coordinator.deliver(9, rep) }.start()
        }

        guard case .delivered(let delivered) = outcome else {
            Issue.record("Expected .delivered from the other thread, got \(outcome)")
            return
        }
        #expect(delivered.inMemoryData == Data("woken".utf8))
        // Without the wake the loop still returns `.delivered` — but only when the
        // window elapses, so the duration is the assertion.
        #expect(clock.now - started < .seconds(Self.window))
    }
}
