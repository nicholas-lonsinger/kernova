import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaAppKitShared

/// Unit tests for which showing holds the status item's popover slot.
@Suite("TransientStatusItemPopover.Tenancy", .caseScoped)
@MainActor
struct TransientStatusItemPopoverTests {
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

    @Test(
        "a click opens the dropdown unless a wait holds the main thread, when it closes a callout or shows the readout",
        arguments: [false, true], [false, true])
    func clickRoute(calloutUp: Bool, mainThreadHeld: Bool) {
        let expected: TransientStatusItemPopover.ClickRoute =
            switch (calloutUp, mainThreadHeld) {
            case (true, true): .dismiss
            case (false, true): .readoutCallout
            case (true, false): .dismissThenMenu
            case (false, false): .menu
            }
        #expect(TransientStatusItemPopover.route(calloutUp: calloutUp, mainThreadHeld: mainThreadHeld) == expected)
    }

    /// A status item with no screen: a click reaches the slot only while the dropdown is detached, and opens the
    /// dropdown itself otherwise.
    final class FakeSurface: StatusItemSurface {
        var isVisible = true
        var isButtonOnScreen = true
        var isMenuAttached = false
        var onClick: (() -> Void)?
        var isCalloutShown = false
        var onCalloutClose: (() -> Void)?
        private(set) var menuOpens = 0
        private(set) var calloutsShown = 0

        /// The user's click on the item.
        func click() {
            if isMenuAttached {
                menuOpens += 1
            } else {
                onClick?()
            }
        }

        func openMenu() {
            isMenuAttached = true
            menuOpens += 1
        }

        func showCallout(_ content: NSViewController) {
            if !isCalloutShown { calloutsShown += 1 }
            isCalloutShown = true
        }

        func closeCallout() {
            isCalloutShown = false
        }
    }

    /// A slot on `surface` whose main thread a wait holds, and whose readout click shows `readout`'s callout
    /// while `readout` says there is one.
    private func makeHeldSlot(_ surface: FakeSurface, readout: @escaping () -> Bool) -> TransientStatusItemPopover {
        let slot = TransientStatusItemPopover(surface: surface, isDropdownOpen: { false }, mainThreadHeld: { true })
        slot.readoutForClick = { [unowned slot] in
            readout() ? slot.show(NSViewController(), for: nil) : .skipped(.noReadout)
        }
        return slot
    }

    @Test("while a wait holds the main thread, a click on the item with the readout's callout up closes it")
    func aHeldClickClosesTheCallout() {
        let surface = FakeSurface()
        let slot = makeHeldSlot(surface, readout: { true })

        surface.click()
        #expect(surface.isCalloutShown)
        surface.click()

        #expect(!surface.isCalloutShown)
        #expect(surface.calloutsShown == 1)
        #expect(surface.menuOpens == 0)
        _ = slot
    }

    @Test("a held click that fell back to the dropdown leaves the next click to show the readout once it closes")
    func aFallbackDropdownLeavesNothingBehind() {
        let surface = FakeSurface()
        var hasReadout = false
        let slot = makeHeldSlot(surface, readout: { hasReadout })

        // No readout yet: the click falls back to the dropdown, which then closes.
        surface.click()
        #expect(surface.menuOpens == 1)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())

        hasReadout = true
        surface.click()

        #expect(surface.menuOpens == 1)
        #expect(surface.isCalloutShown)
        _ = slot
    }
}
