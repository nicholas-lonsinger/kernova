import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Unit tests for `ClipboardProgressFormat` — the wording the host app and the guest
/// agent both render for a clipboard transfer (#643, #652).
@Suite("ClipboardProgressFormat", .caseScoped)
struct ClipboardProgressFormatTests {
    /// A snapshot with everything but the fields under test held constant.
    private static func snapshot(
        peerName: String = "VM", currentItemName: String? = nil, bytesTransferred: UInt64 = 0,
        totalBytes: UInt64 = 1_000
    ) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: .outbound, peerName: peerName, currentItemName: currentItemName, filesCompleted: 0,
            fileCount: 1, bytesTransferred: bytesTransferred, totalBytes: totalBytes, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: .peerPaste, elapsedSeconds: 1)
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

    @Test("the summary of a readout that does not know its bytes counts files, never bytes")
    func summaryUnknownBytes() {
        let snapshot = ClipboardProgressSnapshot(
            direction: .inbound, peerName: "VM", currentItemName: nil, filesCompleted: 250,
            fileCount: 1_000, bytesTransferred: 0, totalBytes: 0, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: .dragOut, elapsedSeconds: 1, bytesKnown: false)
        #expect(ClipboardProgressFormat.summary(snapshot) == "Receiving from “VM”… — 25% — 251 of 1000")
    }

    @Test("the summary falls back to the file's name for a single-file paste")
    func summarySingleItem() {
        let snapshot = Self.snapshot(currentItemName: "big.mov", bytesTransferred: 250)
        #expect(ClipboardProgressFormat.summary(snapshot) == "Pasting into “VM”… — 25% — big.mov")
    }

    @Test("work behind the readout is named, and singular reads as one")
    func pendingNoteCountsWhatIsBehind() {
        #expect(ClipboardProgressFormat.pendingNote(count: 0) == nil)
        #expect(ClipboardProgressFormat.pendingNote(count: 1) == "1 more transfer pending")
        #expect(ClipboardProgressFormat.pendingNote(count: 4) == "4 more transfers pending")
    }
}
