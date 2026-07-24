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

    @Test("the item counter shows the file being worked on, and is absent for a single item")
    func itemCounter() {
        #expect(PasteProgressFormat.itemCounter(completed: 0, total: 1) == nil)
        #expect(PasteProgressFormat.itemCounter(completed: 0, total: 5) == "1 of 5 items")
        #expect(PasteProgressFormat.itemCounter(completed: 2, total: 5) == "3 of 5 items")
        // Never past the total, even in the beat between the last item finishing
        // and the readout clearing.
        #expect(PasteProgressFormat.itemCounter(completed: 5, total: 5) == "5 of 5 items")
    }

    @Test("speed is a byte count per second, and absent without an estimate")
    func speed() {
        #expect(PasteProgressFormat.speed(bytesPerSecond: nil) == nil)
        #expect(PasteProgressFormat.speed(bytesPerSecond: 0) == nil)
        let rate = PasteProgressFormat.speed(bytesPerSecond: 1_500_000)
        #expect(rate?.hasSuffix("/s") == true)
        #expect(rate?.contains("MB") == true)
    }

    @Test("time remaining is bucketed rather than precise")
    func timeRemaining() {
        #expect(PasteProgressFormat.timeRemaining(seconds: nil) == nil)
        #expect(PasteProgressFormat.timeRemaining(seconds: 0) == nil)
        #expect(PasteProgressFormat.timeRemaining(seconds: 3) == "A few seconds remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 30) == "About 30 seconds remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 75) == "About a minute remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 600) == "About 10 minutes remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 3_500) == "About 58 minutes remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 3_700) == "About an hour remaining")
        #expect(PasteProgressFormat.timeRemaining(seconds: 9_000) == "About 3 hours remaining")
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

    @Test("the detail line drops whichever half is missing")
    func detailLine() {
        #expect(PasteProgressFormat.detail(bytesPerSecond: nil, secondsRemaining: nil) == nil)
        #expect(
            PasteProgressFormat.detail(bytesPerSecond: nil, secondsRemaining: 30)
                == "About 30 seconds remaining")
        let both = PasteProgressFormat.detail(bytesPerSecond: 1_500_000, secondsRemaining: 30)
        #expect(both?.contains(" · ") == true)
        #expect(both?.hasSuffix("About 30 seconds remaining") == true)
    }

    @Test("the summary leads with the headline and carries the counter for a multi-item paste")
    func summaryMultipleItems() {
        let snapshot = PasteMaterializationSnapshot(
            sourceName: "VM", currentItemName: "big.mov", itemsCompleted: 1, itemCount: 5,
            bytesTransferred: 500, totalBytes: 1_000, bytesPerSecond: nil, secondsRemaining: nil)
        #expect(PasteProgressFormat.summary(snapshot) == "Pasting from “VM”… — 50% — 2 of 5 items")
    }

    @Test("the summary falls back to the file's name for a single-item paste")
    func summarySingleItem() {
        let snapshot = PasteMaterializationSnapshot(
            sourceName: "VM", currentItemName: "big.mov", itemsCompleted: 0, itemCount: 1,
            bytesTransferred: 250, totalBytes: 1_000, bytesPerSecond: nil, secondsRemaining: nil)
        #expect(PasteProgressFormat.summary(snapshot) == "Pasting from “VM”… — 25% — big.mov")
    }
}
