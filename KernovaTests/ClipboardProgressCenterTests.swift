import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// Unit tests for `ClipboardProgressCenter` — the app-level aggregate the
/// menu-bar status item renders.
///
/// Two VMs can transfer at once, so the interesting behavior is which of several
/// live readouts wins, and that a stopped source stops counting.
@Suite("Clipboard Progress Center Tests")
@MainActor
struct ClipboardProgressCenterTests {
    /// Stands in for a clipboard service: the center keys purely on identity.
    private final class Source {}

    private func makeSnapshot(
        peerName: String, bytesTransferred: UInt64, totalBytes: UInt64
    ) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: .inbound, peerName: peerName, currentItemName: nil, filesCompleted: 0,
            fileCount: 1, bytesTransferred: bytesTransferred, totalBytes: totalBytes,
            bytesPerSecond: nil, secondsRemaining: nil, isPasteSession: false, elapsedSeconds: 0)
    }

    @Test("No source published yet reads as no progress")
    func emptyCenterHasNoProgress() {
        #expect(ClipboardProgressCenter().materializationProgress == nil)
    }

    @Test("The source with the most bytes left to move wins the headline")
    func mostRemainingBytesWins() {
        let center = ClipboardProgressCenter()
        let quiet = Source()
        let busy = Source()

        center.progressChanged(
            from: quiet, makeSnapshot(peerName: "Quiet", bytesTransferred: 900, totalBytes: 1_000))
        center.progressChanged(
            from: busy, makeSnapshot(peerName: "Busy", bytesTransferred: 0, totalBytes: 10_000))

        #expect(center.materializationProgress?.peerName == "Busy")

        // Once the busy VM is nearly done, the other one's remainder wins.
        center.progressChanged(
            from: busy, makeSnapshot(peerName: "Busy", bytesTransferred: 9_990, totalBytes: 10_000))
        #expect(center.materializationProgress?.peerName == "Quiet")
    }

    @Test("Two level readouts break the tie on identity, not on dictionary order")
    func levelReadoutsTieBreakStably() {
        // Dictionary iteration order is unstable, so the identity tie-break is
        // what keeps two equally significant readouts from swapping the status
        // item's headline. Repeated over fresh allocations, the same rule has to
        // decide every time.
        for _ in 0..<50 {
            let center = ClipboardProgressCenter()
            let first = Source()
            let second = Source()
            center.progressChanged(
                from: first, makeSnapshot(peerName: "First", bytesTransferred: 0, totalBytes: 500))
            center.progressChanged(
                from: second, makeSnapshot(peerName: "Second", bytesTransferred: 0, totalBytes: 500))
            let winner = ObjectIdentifier(first) > ObjectIdentifier(second) ? "First" : "Second"
            #expect(center.materializationProgress?.peerName == winner)
        }
    }

    @Test("A nil snapshot drops that source, leaving the survivor")
    func nilSnapshotDropsTheSource() {
        let center = ClipboardProgressCenter()
        let stopping = Source()
        let running = Source()

        center.progressChanged(
            from: stopping,
            makeSnapshot(peerName: "Stopping", bytesTransferred: 0, totalBytes: 10_000))
        center.progressChanged(
            from: running, makeSnapshot(peerName: "Running", bytesTransferred: 0, totalBytes: 100))
        #expect(center.materializationProgress?.peerName == "Stopping")

        center.progressChanged(from: stopping, nil)
        #expect(center.materializationProgress?.peerName == "Running")

        center.progressChanged(from: running, nil)
        #expect(center.materializationProgress == nil)
    }

    @Test("A source that transferred more bytes than it declared reads as finished")
    func overshootClampsToZeroRemaining() {
        let center = ClipboardProgressCenter()
        let overshooting = Source()
        let ordinary = Source()

        center.progressChanged(
            from: overshooting,
            makeSnapshot(peerName: "Overshooting", bytesTransferred: 5_000, totalBytes: 1_000))
        center.progressChanged(
            from: ordinary, makeSnapshot(peerName: "Ordinary", bytesTransferred: 0, totalBytes: 10))

        // No underflow trap, and the clamped remainder (0) loses to the real one.
        #expect(center.materializationProgress?.peerName == "Ordinary")
    }
}
