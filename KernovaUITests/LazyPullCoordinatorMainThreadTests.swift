import AppKit
import Foundation
import KernovaSynchronization
import Testing

@testable import KernovaKit

/// The main-thread branch of `LazyPullCoordinator.pull` — the wait that runs the
/// application's event loop instead of parking. It needs a live `NSApplication`,
/// which only this app-hosted bundle has.
@Suite("LazyPullCoordinator on the main thread", .caseScoped)
@MainActor
struct LazyPullCoordinatorMainThreadTests {
    // Each test holds the real main thread inside `pull` from a main-queue job,
    // where the nested loop cannot drain the main queue (`NestedEventLoopWait`),
    // so this caps how long the bundle's MainActor is held if the fast path
    // loses — the exception `testWaitBackstop` names. Every fast path here is
    // ms-scale and same-thread, so 5 s never masks a failure.
    private static let window: TimeInterval = 5

    /// Subtype of the event that sequences `nestedWaitsBothResolve`'s inner
    /// delivery behind the outer's wake.
    private nonisolated static let markerSubtype: Int16 = 0x7E57

    private nonisolated func inlineRep(_ text: String) -> ClipboardContent.Representation {
        ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data(text.utf8))
    }

    /// A coordinator whose main-thread waits block each `nextEvent` at most
    /// `slice`, recording every wait it vends into `waits` in order.
    private nonisolated func coordinator(
        slice: TimeInterval, recordingInto waits: Locked<[NestedEventLoopWait]>
    ) -> LazyPullCoordinator {
        LazyPullCoordinator(eventLoopWait: {
            let wait = NestedEventLoopWait.current(slice: slice)
            if let wait { waits.withLock { $0.append(wait) } }
            return wait
        })
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

    @Test("a main-thread hold keeps the run loop turning: a block performed on it opens the latch")
    func performedMainRunLoopBlockEndsHold() throws {
        let waits = Locked<[NestedEventLoopWait]>([])
        let coordinator = coordinator(slice: NestedEventLoopWait.defaultSlice, recordingInto: waits)
        let latch = OneShotLatch()
        // Scheduled before the hold. A parked wait could only run it after
        // returning, which nothing else would let it do.
        RunLoop.main.perform { latch.open() }
        // The hold has no deadline of its own: a lost fast path is ended by
        // the test plan's per-test allowance.
        let refusal = coordinator.hold(until: latch)

        #expect(refusal == nil)
        let waitsTaken = waits.withLock { $0 }
        try #require(waitsTaken.count == 1)
        #expect(waitsTaken[0].endingsForTesting == [.resolved])
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

    @Test("an inner wait that consumed the outer's wake hands it a fresh one, so both waits end resolved (#860)")
    func nestedWaitsBothResolve() throws {
        let waits = Locked<[NestedEventLoopWait]>([])
        // A slice past the deadline: only the inner's exit wake can end the
        // outer's `nextEvent` before it.
        let coordinator = coordinator(slice: Self.window * 2, recordingInto: waits)
        let innerResolved = Locked(false)
        // Dispatching the marker queues the inner's delivery, so the inner is
        // waiting again when that delivery's wake lands, and dequeues it too.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
            if event.subtype.rawValue == Self.markerSubtype {
                RunLoop.main.perform { coordinator.deliver(2, self.inlineRep("inner")) }
            }
            return event
        }
        defer { monitor.map(NSEvent.removeMonitor) }

        let outcome = coordinator.pull(transferID: 1, timeout: Self.window, retire: {}) {
            RunLoop.main.perform {
                let inner = coordinator.pull(transferID: 2, timeout: Self.window, retire: {}) {
                    // The outer's wake and then the marker are queued in one
                    // run-loop pass, so the inner dequeues and discards that
                    // wake before the marker's dispatch resolves the inner.
                    coordinator.deliver(1, self.inlineRep("outer"))
                    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                        MainActor.assumeIsolated {
                            guard
                                let marker = NSEvent.otherEvent(
                                    with: .applicationDefined, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: 0, context: nil,
                                    subtype: Self.markerSubtype, data1: 0, data2: 0)
                            else {
                                Issue.record("NSEvent.otherEvent refused the marker")
                                return
                            }
                            NSApp.postEvent(marker, atStart: false)
                        }
                    }
                }
                if case .delivered(let rep) = inner, rep.inMemoryData == Data("inner".utf8) {
                    innerResolved.withLock { $0 = true }
                }
            }
        }

        guard case .delivered(let rep) = outcome else {
            Issue.record("Expected the outer pull to deliver, got \(outcome)")
            return
        }
        #expect(rep.inMemoryData == Data("outer".utf8))
        #expect(innerResolved.withLock { $0 })
        let waitsTaken = waits.withLock { $0 }
        try #require(waitsTaken.count == 2)
        // A stranded outer still delivers — its outcome was set — but only once
        // its wait reaches the deadline.
        #expect(waitsTaken[0].endingsForTesting == [.resolved], "outer")
        #expect(waitsTaken[1].endingsForTesting == [.resolved], "inner")
    }

    @Test("a loop run inside the wait that takes its wake leaves the slice to end the wait resolved")
    func sliceRecoversWakeTakenByForeignLoop() throws {
        let waits = Locked<[NestedEventLoopWait]>([])
        let coordinator = coordinator(slice: NestedEventLoopWait.defaultSlice, recordingInto: waits)
        let foreignTookEvent = Locked(false)
        let foreignWindow = Self.window

        let outcome = coordinator.pull(transferID: 3, timeout: Self.window, retire: {}) {
            // A callout inside the wait's `nextEvent`, as `performOnMainRunLoop`
            // runs one: resolve the pull, then run a tracking-mode loop that
            // takes the wake before control returns to the wait.
            RunLoop.main.perform {
                coordinator.deliver(3, self.inlineRep("foreign"))
                MainActor.assumeIsolated {
                    let taken = NSApp.nextEvent(
                        matching: .applicationDefined,
                        until: Date(timeIntervalSinceNow: foreignWindow),
                        inMode: .eventTracking, dequeue: true)
                    foreignTookEvent.withLock { $0 = taken != nil }
                }
            }
        }

        guard case .delivered(let rep) = outcome else {
            Issue.record("Expected the pull to deliver, got \(outcome)")
            return
        }
        #expect(rep.inMemoryData == Data("foreign".utf8))
        #expect(foreignTookEvent.withLock { $0 })
        let waitsTaken = waits.withLock { $0 }
        try #require(waitsTaken.count == 1)
        // Nothing returns from the wait's `nextEvent` once the foreign loop
        // ends; only the slice re-checks before the deadline.
        #expect(waitsTaken[0].endingsForTesting == [.resolved])
    }
}
