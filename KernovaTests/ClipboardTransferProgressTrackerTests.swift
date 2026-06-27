import Testing

@testable import Kernova

@Suite("ClipboardTransferProgressTracker")
struct ClipboardTransferProgressTrackerTests {
    @Test("an unrevealed transfer is not projected until revealed")
    func revealGatesProjection() {
        let tracker = ClipboardTransferProgressTracker()
        _ = tracker.record(1, direction: .inbound, bytes: 10, total: 100, label: nil)
        #expect(tracker.projection() == nil)
        #expect(tracker.reveal(1))
        #expect(tracker.projection()?.totalBytes == 100)
    }

    @Test("projection prefers the transfer with the most bytes remaining")
    func prefersMostRemaining() {
        let tracker = ClipboardTransferProgressTracker()
        // A completed transfer lingering at 100% (0 remaining)…
        _ = tracker.record(1, direction: .inbound, bytes: 100, total: 100, label: nil)
        // …and a freshly-started active one (150 remaining).
        _ = tracker.record(2, direction: .outbound, bytes: 50, total: 200, label: nil)
        #expect(tracker.reveal(1))
        #expect(tracker.reveal(2))
        // The active transfer wins, so the bar never shows the completed 100%.
        let projection = tracker.projection()
        #expect(projection?.direction == .outbound)
        #expect(projection?.totalBytes == 200)
    }

    @Test("finish removes a transfer from the projection")
    func finishClears() {
        let tracker = ClipboardTransferProgressTracker()
        _ = tracker.record(1, direction: .inbound, bytes: 10, total: 100, label: nil)
        #expect(tracker.reveal(1))
        tracker.finish(1)
        #expect(tracker.projection() == nil)
        // A reveal after finish is a no-op (can't resurrect).
        #expect(tracker.reveal(1) == false)
    }

    @Test("record conflates flushes until consumeFlush re-arms")
    func flushConflation() {
        let tracker = ClipboardTransferProgressTracker()
        #expect(tracker.record(1, direction: .inbound, bytes: 10, total: 100, label: nil) == .created)
        #expect(
            tracker.record(1, direction: .inbound, bytes: 20, total: 100, label: nil)
                == .updatedScheduleFlush)
        #expect(
            tracker.record(1, direction: .inbound, bytes: 30, total: 100, label: nil)
                == .updatedSuppressed)
        _ = tracker.consumeFlush()  // clears the conflation flag
        #expect(
            tracker.record(1, direction: .inbound, bytes: 40, total: 100, label: nil)
                == .updatedScheduleFlush)
    }

    @Test("clearAll drops every transfer")
    func clearAllDrops() {
        let tracker = ClipboardTransferProgressTracker()
        _ = tracker.record(1, direction: .inbound, bytes: 10, total: 100, label: nil)
        #expect(tracker.reveal(1))
        tracker.clearAll()
        #expect(tracker.projection() == nil)
    }
}
