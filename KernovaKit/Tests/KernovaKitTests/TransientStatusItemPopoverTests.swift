import KernovaTestSupport
import Testing

@testable import KernovaAppKitShared

/// Unit tests for which showing holds the status item's popover slot.
@Suite("TransientStatusItemPopover.Tenancy", .caseScoped)
@MainActor
struct TransientStatusItemPopoverTests {
    @Test("a showing a newer callout replaced cannot end the newer one")
    func aStaleShowingLeavesTheNewerOneUp() throws {
        var tenancy = TransientStatusItemPopover.Tenancy()
        let readoutBegun = tenancy.begin(timed: false)
        let readout = try #require(readoutBegun)
        let noticeBegun = tenancy.begin(timed: true)
        let notice = try #require(noticeBegun)

        // The readout clearing after a notice took the slot must leave it up.
        let endedReadout = tenancy.end(readout)
        #expect(!endedReadout)
        #expect(tenancy.current == notice)

        let endedNotice = tenancy.end(notice)
        #expect(endedNotice)
        #expect(tenancy.current == nil)
    }

    @Test("a showing ends once, and not after the slot was emptied from elsewhere")
    func aShowingEndsOnce() throws {
        var tenancy = TransientStatusItemPopover.Tenancy()
        let readoutBegun = tenancy.begin(timed: false)
        let readout = try #require(readoutBegun)
        // A click on the status item empties the slot whoever holds it.
        tenancy.endAny()

        let endedAfterEmptying = tenancy.end(readout)
        #expect(!endedAfterEmptying)
        let nextBegun = tenancy.begin(timed: false)
        let next = try #require(nextBegun)
        let endedUnderNext = tenancy.end(readout)
        #expect(!endedUnderNext)
        #expect(tenancy.current == next)
    }

    @Test("an untimed callout never displaces a timed one before its time is up")
    func anUntimedShowingWaitsForATimedOne() throws {
        var tenancy = TransientStatusItemPopover.Tenancy()
        let noticeBegun = tenancy.begin(timed: true)
        let notice = try #require(noticeBegun)

        // The readout's reveal is skipped, so it stays unspent.
        let readoutWhileNoticeUp = tenancy.begin(timed: false)
        #expect(readoutWhileNoticeUp == nil)
        #expect(tenancy.current == notice)

        // The notice's timer ends it, and the next reveal goes up.
        let endedNotice = tenancy.end(notice)
        #expect(endedNotice)
        let readout = tenancy.begin(timed: false)
        #expect(readout != nil)
        #expect(tenancy.current == readout)
    }

    @Test("a timed callout replaces anything, and an untimed one replaces an untimed one")
    func replacementOtherwise() throws {
        var tenancy = TransientStatusItemPopover.Tenancy()
        let firstBegun = tenancy.begin(timed: false)
        let first = try #require(firstBegun)
        let secondBegun = tenancy.begin(timed: false)
        let second = try #require(secondBegun)
        #expect(first != second)
        #expect(tenancy.current == second)

        let noticeBegun = tenancy.begin(timed: true)
        let notice = try #require(noticeBegun)
        let reminderBegun = tenancy.begin(timed: true)
        let reminder = try #require(reminderBegun)
        #expect(notice != reminder)
        #expect(tenancy.current == reminder)
    }
}
