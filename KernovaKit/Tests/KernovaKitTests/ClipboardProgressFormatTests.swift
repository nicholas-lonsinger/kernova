import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `ClipboardProgressFormat` — the wording the host app and the guest
/// agent both render for a clipboard transfer (#643, #652).
@Suite("ClipboardProgressFormat", .admissionGated)
struct ClipboardProgressFormatTests {
    /// A snapshot with everything but the fields under test held constant.
    private static func snapshot(
        direction: ClipboardProgressSnapshot.Direction = .outbound, peerName: String = "VM",
        currentItemName: String? = nil, filesCompleted: Int = 0, fileCount: Int = 1,
        bytesTransferred: UInt64 = 0, totalBytes: UInt64 = 1_000,
        gesture: ClipboardTransferGesture = .peerPaste, pendingBehind: Int = 0
    ) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: direction, peerName: peerName, currentItemName: currentItemName,
            filesCompleted: filesCompleted, fileCount: fileCount,
            bytesTransferred: bytesTransferred, totalBytes: totalBytes, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: gesture, elapsedSeconds: 1,
            pendingBehind: pendingBehind)
    }

    @Test("the headline names the peer in quotes and says what is happening")
    func headlineNamesPeer() {
        // A paste is named as such: the bytes are leaving for an app on the other
        // machine that is blocked until they land, which is the whole reason the
        // readout interrupted.
        #expect(
            ClipboardProgressFormat.headline(
                direction: .outbound, peerName: "macOS TEST", gesture: .peerPaste)
                == "Pasting into “macOS TEST”…")
        #expect(
            ClipboardProgressFormat.headline(
                direction: .outbound, peerName: "macOS TEST", gesture: .paste)
                == "Sending to “macOS TEST”…")
        #expect(
            ClipboardProgressFormat.headline(
                direction: .inbound, peerName: "macOS TEST", gesture: .paste)
                == "Receiving from “macOS TEST”…")
    }

    @Test("the file counter shows the file being worked on, and is absent for a single file")
    func itemCounter() {
        #expect(ClipboardProgressFormat.itemCounter(completed: 0, total: 1) == nil)
        #expect(ClipboardProgressFormat.itemCounter(completed: 0, total: 5) == "1 of 5")
        #expect(ClipboardProgressFormat.itemCounter(completed: 2, total: 5) == "3 of 5")
        // Never past the total, even in the beat between the last file finishing
        // and the readout clearing.
        #expect(ClipboardProgressFormat.itemCounter(completed: 5, total: 5) == "5 of 5")
    }

    @Test("speed is a byte count per second, and absent without an estimate")
    func speed() {
        #expect(ClipboardProgressFormat.speed(bytesPerSecond: nil) == nil)
        #expect(ClipboardProgressFormat.speed(bytesPerSecond: 0) == nil)
        let rate = ClipboardProgressFormat.speed(bytesPerSecond: 1_500_000)
        #expect(rate?.hasSuffix("/s") == true)
        #expect(rate?.contains("MB") == true)
    }

    @Test("time remaining spells minutes and seconds under an hour, coarsens above it")
    func timeRemaining() {
        #expect(ClipboardProgressFormat.timeRemaining(seconds: nil) == nil)
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 0) == nil)
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 0.4) == "1 second remaining")
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 3) == "3 seconds remaining")
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 30) == "30 seconds remaining")
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 60) == "1 minute, 0 seconds remaining")
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 75) == "1 minute, 15 seconds remaining")
        #expect(
            ClipboardProgressFormat.timeRemaining(seconds: 387) == "6 minutes, 27 seconds remaining")
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 3_600) == "1 hour remaining")
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 3_700) == "1 hour, 1 minute remaining")
        #expect(ClipboardProgressFormat.timeRemaining(seconds: 9_000) == "2 hours, 30 minutes remaining")
    }

    @Test("an infinite estimate is treated as no estimate")
    func infiniteTimeRemainingRejected() {
        #expect(ClipboardProgressFormat.timeRemaining(seconds: .infinity) == nil)
    }

    @Test("percent floors, so it never reads complete early")
    func percent() {
        #expect(ClipboardProgressFormat.percent(fraction: 0) == "0%")
        #expect(ClipboardProgressFormat.percent(fraction: 0.999) == "99%")
        #expect(ClipboardProgressFormat.percent(fraction: 1) == "100%")
        #expect(ClipboardProgressFormat.percent(fraction: 1.4) == "100%")
        #expect(ClipboardProgressFormat.percent(fraction: -1) == "0%")
    }

    @Test("the byte-progress line carries the speed parenthetical only once one exists")
    func byteProgressLine() {
        let withoutSpeed = ClipboardProgressFormat.byteProgress(
            bytesTransferred: 47_600_000, totalBytes: 3_030_000_000, bytesPerSecond: nil)
        #expect(withoutSpeed.contains(" of ") == true)
        #expect(withoutSpeed.contains("(") == false)
        let withSpeed = ClipboardProgressFormat.byteProgress(
            bytesTransferred: 47_600_000, totalBytes: 3_030_000_000, bytesPerSecond: 7_800_000)
        #expect(withSpeed.contains(" of ") == true)
        #expect(withSpeed.hasSuffix("/s)") == true)
        #expect(withSpeed.contains("(") == true)
    }

    @Test("the summary leads with the headline and carries the counter for a multi-file paste")
    func summaryMultipleItems() {
        let snapshot = Self.snapshot(
            currentItemName: "big.mov", filesCompleted: 1, fileCount: 5, bytesTransferred: 500)
        #expect(ClipboardProgressFormat.summary(snapshot) == "Pasting into “VM”… — 50% — 2 of 5")
    }

    @Test("the summary falls back to the file's name for a single-file paste")
    func summarySingleItem() {
        let snapshot = Self.snapshot(currentItemName: "big.mov", bytesTransferred: 250)
        #expect(ClipboardProgressFormat.summary(snapshot) == "Pasting into “VM”… — 25% — big.mov")
    }

    @Test("the summary carries the direction for a transfer that is not a paste")
    func summaryNonPaste() {
        let snapshot = Self.snapshot(
            direction: .inbound, currentItemName: "big.mov", bytesTransferred: 250,
            gesture: .paste)
        #expect(ClipboardProgressFormat.summary(snapshot) == "Receiving from “VM”… — 25% — big.mov")
    }

    @Test("work behind the readout is named, and singular reads as one")
    func pendingNoteCountsWhatIsBehind() {
        #expect(ClipboardProgressFormat.pendingNote(count: 0) == nil)
        #expect(ClipboardProgressFormat.pendingNote(count: 1) == "1 more transfer pending")
        #expect(ClipboardProgressFormat.pendingNote(count: 4) == "4 more transfers pending")
    }

    @Test("the summary carries what is queued behind the transfer it describes")
    func summaryCarriesWhatIsPending() {
        let snapshot = Self.snapshot(
            direction: .outbound, currentItemName: "big.mov", bytesTransferred: 250,
            gesture: .drop, pendingBehind: 2)
        #expect(
            ClipboardProgressFormat.summary(snapshot)
                == "Sending to “VM”… — 25% — big.mov — 2 more transfers pending")
    }
}
