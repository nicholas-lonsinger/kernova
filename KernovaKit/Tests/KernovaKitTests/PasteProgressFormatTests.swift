import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `PasteProgressFormat` — the wording the host app and the guest
/// agent both render for a materializing paste (#643).
@Suite("PasteProgressFormat")
struct PasteProgressFormatTests {
    @Test("the headline names the source in quotes")
    func headlineNamesSource() {
        #expect(PasteProgressFormat.headline(sourceName: "macOS TEST") == "Pasting from “macOS TEST”…")
    }

    @Test("the file counter shows the file being worked on, and is absent for a single file")
    func itemCounter() {
        #expect(PasteProgressFormat.itemCounter(completed: 0, total: 1) == nil)
        #expect(PasteProgressFormat.itemCounter(completed: 0, total: 5) == "1 of 5")
        #expect(PasteProgressFormat.itemCounter(completed: 2, total: 5) == "3 of 5")
        // Never past the total, even in the beat between the last file finishing
        // and the readout clearing.
        #expect(PasteProgressFormat.itemCounter(completed: 5, total: 5) == "5 of 5")
    }

    @Test("speed is a byte count per second, and absent without an estimate")
    func speed() {
        #expect(PasteProgressFormat.speed(bytesPerSecond: nil) == nil)
        #expect(PasteProgressFormat.speed(bytesPerSecond: 0) == nil)
        let rate = PasteProgressFormat.speed(bytesPerSecond: 1_500_000)
        #expect(rate?.hasSuffix("/s") == true)
        #expect(rate?.contains("MB") == true)
    }

    @Test("time remaining spells minutes and seconds under an hour, coarsens above it")
    func timeRemaining() {
        #expect(PasteProgressFormat.timeRemaining(seconds: nil) == nil)
        #expect(PasteProgressFormat.timeRemaining(seconds: 0) == nil)
        #expect(PasteProgressFormat.timeRemaining(seconds: 0.4) == "1 second remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 3) == "3 seconds remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 30) == "30 seconds remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 60) == "1 minute, 0 seconds remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 75) == "1 minute, 15 seconds remaining")
        #expect(
            PasteProgressFormat.timeRemaining(seconds: 387) == "6 minutes, 27 seconds remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 3_600) == "1 hour remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 3_700) == "1 hour, 1 minute remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 9_000) == "2 hours, 30 minutes remaining")
    }

    @Test("an infinite estimate is treated as no estimate")
    func infiniteTimeRemainingRejected() {
        #expect(PasteProgressFormat.timeRemaining(seconds: .infinity) == nil)
    }

    @Test("percent floors, so it never reads complete early")
    func percent() {
        #expect(PasteProgressFormat.percent(fraction: 0) == "0%")
        #expect(PasteProgressFormat.percent(fraction: 0.999) == "99%")
        #expect(PasteProgressFormat.percent(fraction: 1) == "100%")
        #expect(PasteProgressFormat.percent(fraction: 1.4) == "100%")
        #expect(PasteProgressFormat.percent(fraction: -1) == "0%")
    }

    @Test("the byte-progress line carries the speed parenthetical only once one exists")
    func byteProgressLine() {
        let withoutSpeed = PasteProgressFormat.byteProgress(
            bytesTransferred: 47_600_000, totalBytes: 3_030_000_000, bytesPerSecond: nil)
        #expect(withoutSpeed.contains(" of ") == true)
        #expect(withoutSpeed.contains("(") == false)
        let withSpeed = PasteProgressFormat.byteProgress(
            bytesTransferred: 47_600_000, totalBytes: 3_030_000_000, bytesPerSecond: 7_800_000)
        #expect(withSpeed.contains(" of ") == true)
        #expect(withSpeed.hasSuffix("/s)") == true)
        #expect(withSpeed.contains("(") == true)
    }

    @Test("the summary leads with the headline and carries the counter for a multi-file paste")
    func summaryMultipleItems() {
        let snapshot = PasteMaterializationSnapshot(
            sourceName: "VM", currentItemName: "big.mov", filesCompleted: 1, fileCount: 5,
            bytesTransferred: 500, totalBytes: 1_000, bytesPerSecond: nil, secondsRemaining: nil)
        #expect(PasteProgressFormat.summary(snapshot) == "Pasting from “VM”… — 50% — 2 of 5")
    }

    @Test("the summary falls back to the file's name for a single-file paste")
    func summarySingleItem() {
        let snapshot = PasteMaterializationSnapshot(
            sourceName: "VM", currentItemName: "big.mov", filesCompleted: 0, fileCount: 1,
            bytesTransferred: 250, totalBytes: 1_000, bytesPerSecond: nil, secondsRemaining: nil)
        #expect(PasteProgressFormat.summary(snapshot) == "Pasting from “VM”… — 25% — big.mov")
    }
}
