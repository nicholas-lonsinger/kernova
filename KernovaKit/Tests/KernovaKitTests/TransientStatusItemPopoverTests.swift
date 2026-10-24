import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Unit tests for which showing holds the status item's popover slot.
@Suite("TransientStatusItemPopover.Tenancy", .caseScoped)
@MainActor
struct TransientStatusItemPopoverTests {
    @Test("a showing a newer callout replaced cannot end the newer one")
    func aStaleShowingLeavesTheNewerOneUp() {
        var tenancy = TransientStatusItemPopover.Tenancy()
        let readout = tenancy.begin()
        let notice = tenancy.begin()

        // The readout clearing after a notice took the slot must leave it up.
        let endedReadout = tenancy.end(readout)
        #expect(!endedReadout)
        #expect(tenancy.current == notice)

        let endedNotice = tenancy.end(notice)
        #expect(endedNotice)
        #expect(tenancy.current == nil)
    }

    @Test("a showing ends once, and not after the slot was emptied from elsewhere")
    func aShowingEndsOnce() {
        var tenancy = TransientStatusItemPopover.Tenancy()
        let readout = tenancy.begin()
        // A click on the status item empties the slot whoever holds it.
        tenancy.endAny()

        let endedAfterEmptying = tenancy.end(readout)
        #expect(!endedAfterEmptying)
        let next = tenancy.begin()
        let endedUnderNext = tenancy.end(readout)
        #expect(!endedUnderNext)
        #expect(tenancy.current == next)
    }
}
