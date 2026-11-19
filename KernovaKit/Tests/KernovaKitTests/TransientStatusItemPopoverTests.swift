import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaAppKitShared

/// Unit tests for which showing holds the status item's popover slot.
@Suite("TransientStatusItemPopover.Tenancy", .caseScoped)
@MainActor
struct TransientStatusItemPopoverTests {
    nonisolated private static let readout = CalloutLifetime.heldByOwner
    nonisolated private static let information = CalloutLifetime.informational(seconds: 4.5)
    nonisolated private static let error = CalloutLifetime.error(announcement: "Files not copied.")

    @Test("a showing ends once, and not after the slot was emptied from elsewhere")
    func aShowingEndsOnce() throws {
        var tenancy = TransientStatusItemPopover.Tenancy()
        let readoutBegun = tenancy.begin(Self.readout)
        let readout = try #require(readoutBegun)
        // A click on the status item empties the slot whoever holds it.
        tenancy.endAny()

        let endedAfterEmptying = tenancy.end(readout)
        #expect(!endedAfterEmptying)
        let nextBegun = tenancy.begin(Self.readout)
        let next = try #require(nextBegun)
        let endedUnderNext = tenancy.end(readout)
        #expect(!endedUnderNext)
        #expect(tenancy.current == next)
    }

    /// Every lifetime up, then every lifetime asking for the slot, with whether
    /// it takes the slot: an error stays until clicked, so only a newer error
    /// takes it; information gives way to an error but not to a readout.
    nonisolated private static let takeovers: [(up: CalloutLifetime, asking: CalloutLifetime, takes: Bool)] = [
        (readout, readout, true), (readout, information, true), (readout, error, true),
        (information, readout, false), (information, information, true), (information, error, true),
        (error, readout, false), (error, information, false), (error, error, true),
    ]

    @Test("a callout takes the slot from one up only as the kinds allow", arguments: takeovers.indices)
    func takeover(_ pair: Int) throws {
        let (up, asking, takes) = Self.takeovers[pair]
        var tenancy = TransientStatusItemPopover.Tenancy()
        let upBegun = tenancy.begin(up)
        let first = try #require(upBegun)

        let asked = tenancy.begin(asking)

        #expect((asked != nil) == takes)
        #expect(tenancy.current == (takes ? asked : first))
        // Whatever holds the slot ends only by its own showing.
        if !takes {
            let ended = tenancy.end(first)
            let askedAgain = tenancy.begin(asking)
            #expect(ended)
            #expect(askedAgain != nil)
        }
    }

    @Test("an error callout is dismissed by a click anywhere on it, or by VoiceOver pressing it")
    func anErrorIsDismissedByAClick() throws {
        var dismissals = 0
        let content = NSViewController()
        content.installCalloutStack(rows: [makeCalloutHeadline("Files not copied."), makeCalloutBody("2 of 3.")])
        let callout = ClickToDismissCalloutController(
            content: content, label: "Files not copied. 2 of 3.", onDismiss: { dismissals += 1 })
        let view = callout.view
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()

        // A point over the headline, which a plain container would hand to it.
        let headline = try #require(content.view.subviews.first?.subviews.first)
        let overHeadline = view.convert(NSPoint(x: headline.bounds.midX, y: headline.bounds.midY), from: headline)
        #expect(view.hitTest(overHeadline) === view)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: overHeadline, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        #expect(dismissals == 1)

        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .button)
        #expect(view.accessibilityLabel() == "Files not copied. 2 of 3.")
        #expect(view.accessibilityPerformPress())
        #expect(dismissals == 2)
    }
}
