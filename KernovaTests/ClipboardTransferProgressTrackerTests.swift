import KernovaKit
import Testing

@testable import Kernova

@Suite("ClipboardTransferProgressTracker")
struct ClipboardTransferProgressTrackerTests {
    /// A total big enough that the throttle's ~1% byte quantum is many chunks wide,
    /// so "sub-quantum" and "past the quantum" are unambiguous.
    private let total = 1_000_000
    /// The byte advance the shared throttle needs before it admits another update
    /// (derived, so a policy change moves these tests with it).
    private var quantum: Int { Int(Double(total) * FetchProgressThrottle.minByteFraction) }

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
        #expect(tracker.reveal(1))
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

    // MARK: - Shared republish-rate throttle (#636)

    /// Records a chunk for the single transfer these throttle tests use.
    private func record(
        _ tracker: ClipboardTransferProgressTracker, bytes: Int
    ) -> ClipboardTransferProgressTracker.RecordOutcome {
        tracker.record(1, direction: .inbound, bytes: bytes, total: total, label: nil)
    }

    /// A revealed transfer with its first post-reveal update already forwarded and
    /// flushed, so the coalescer's byte watermark sits at `bytes` and the next
    /// chunk faces the real quantum gate.
    private func makeRevealedTracker(forwardedTo bytes: Int) -> ClipboardTransferProgressTracker {
        let tracker = ClipboardTransferProgressTracker()
        #expect(record(tracker, bytes: 1) == .created)
        #expect(tracker.reveal(1))
        // The coalescer's first forward-progress update always passes.
        #expect(record(tracker, bytes: bytes) == .updatedScheduleFlush)
        _ = tracker.consumeFlush()
        return tracker
    }

    @Test("a sub-quantum chunk after a forwarded one is suppressed")
    func subQuantumChunkSuppressed() {
        let tracker = makeRevealedTracker(forwardedTo: quantum * 10)
        // A tenth of the quantum: far under the byte gate, and this runs in the
        // same synchronous block, so the throttle's ~100 ms time gate is closed
        // too — the update carries nothing the bar could show yet.
        #expect(record(tracker, bytes: quantum * 10 + quantum / 10) == .updatedSuppressed)
    }

    @Test("a chunk advancing a full quantum schedules another flush")
    func quantumChunkSchedulesFlush() {
        let tracker = makeRevealedTracker(forwardedTo: quantum * 10)
        #expect(record(tracker, bytes: quantum * 11) == .updatedScheduleFlush)
    }

    @Test("the final chunk always schedules a flush, however small its advance")
    func finalChunkAlwaysSchedulesFlush() {
        let tracker = makeRevealedTracker(forwardedTo: total - 1)
        // One byte past the watermark — nowhere near the quantum — but it completes
        // the transfer, so the bar must reach 100%.
        #expect(record(tracker, bytes: total) == .updatedScheduleFlush)
    }

    @Test("an unrevealed transfer never schedules a flush")
    func unrevealedNeverSchedulesFlush() {
        let tracker = ClipboardTransferProgressTracker()
        #expect(record(tracker, bytes: 1) == .created)
        // A flush would publish nothing — the projection ignores unrevealed
        // transfers — so even a quantum-sized advance, and even the final chunk,
        // stay suppressed.
        #expect(record(tracker, bytes: quantum * 10) == .updatedSuppressed)
        #expect(record(tracker, bytes: total) == .updatedSuppressed)
        #expect(tracker.projection() == nil)
    }

    @Test("a suppressed chunk still advances the bytes the next flush publishes")
    func suppressedChunkStillAdvancesBytes() {
        let tracker = makeRevealedTracker(forwardedTo: quantum * 10)
        #expect(tracker.projection()?.bytesTransferred == quantum * 10)
        // Two sub-quantum chunks, both suppressed…
        #expect(record(tracker, bytes: quantum * 10 + 1) == .updatedSuppressed)
        #expect(record(tracker, bytes: quantum * 10 + 2) == .updatedSuppressed)
        // …yet the freshest count is what the next flush reads, so nothing is lost
        // by not republishing per chunk.
        #expect(tracker.consumeFlush()?.bytesTransferred == quantum * 10 + 2)
    }
}
