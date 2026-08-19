import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `ClipboardProgressMenuAutoOpener` — the rules that let a
/// materializing paste open the status-item dropdown by itself, once (#643, #652).
@Suite("ClipboardProgressMenuAutoOpener", .admissionGated)
struct ClipboardProgressMenuAutoOpenerTests {
    /// A readout that clears every gate, so each test varies only what it is about.
    ///
    /// Outbound, the shape a paste readout has: this side is streaming the bytes
    /// an app on the peer is blocked on.
    private static func readout(
        elapsed: TimeInterval = 5, secondsRemaining: Double? = 10, bytesTransferred: UInt64 = 100,
        totalBytes: UInt64 = 1_000, gesture: ClipboardTransferGesture = .peerPaste
    ) -> ClipboardProgressSnapshot {
        ClipboardProgressSnapshot(
            direction: .outbound, peerName: "VM", currentItemName: nil, filesCompleted: 0,
            fileCount: 1, bytesTransferred: bytesTransferred, totalBytes: totalBytes,
            bytesPerSecond: 100, secondsRemaining: secondsRemaining, gesture: gesture,
            elapsedSeconds: elapsed)
    }

    @Test("a paste's first readout opens the dropdown")
    func firstReadoutOpens() {
        var opener = ClipboardProgressMenuAutoOpener()
        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("later updates in the same paste never re-open")
    func laterUpdatesDoNotReopen() {
        var opener = ClipboardProgressMenuAutoOpener()
        _ = opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true)
        opener.menuOpened(automatically: true)
        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: true, canOpen: true) == .none)
    }

    @Test("a dropdown the user dismissed stays closed for the rest of the paste")
    func userDismissalIsFinalForThePaste() {
        var opener = ClipboardProgressMenuAutoOpener()
        _ = opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true)
        opener.menuOpened(automatically: true)
        opener.menuClosed()

        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true) == .none)
    }

    @Test("the paste closes only the dropdown it opened")
    func closesOnlyItsOwnDropdown() {
        var opener = ClipboardProgressMenuAutoOpener()
        _ = opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true)
        opener.menuOpened(automatically: true)

        #expect(opener.readoutChanged(nil, menuIsOpen: true, canOpen: true) == .close)
    }

    @Test("a dropdown the user opened is left alone when the paste ends")
    func leavesAUserOpenedDropdownAlone() {
        var opener = ClipboardProgressMenuAutoOpener()
        _ = opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true)
        // The user got there first — this is their dropdown, not the paste's.
        opener.menuOpened(automatically: false)

        #expect(opener.readoutChanged(nil, menuIsOpen: true, canOpen: true) == .none)
    }

    @Test("a readout appearing while the dropdown is already open opens nothing")
    func alreadyOpenNeedsNoOpen() {
        var opener = ClipboardProgressMenuAutoOpener()
        opener.menuOpened(automatically: false)
        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: true, canOpen: true) == .none)
    }

    @Test("closing a dropdown the readout appeared inside does not make it pop back open")
    func dismissingADropdownTheReadoutAppearedInIsFinal() {
        var opener = ClipboardProgressMenuAutoOpener()
        // The user opened the dropdown for their own reasons, and the paste's
        // readout then revealed into it — so the paste has had its showing even
        // though it never asked for the open.
        opener.menuOpened(automatically: false)
        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: true, canOpen: true) == .none)

        opener.menuClosed()
        // Dismissing it is the user saying no. The next throttled update must not
        // answer that by popping the dropdown straight back up.
        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true) == .none)
    }

    @Test("an off-screen status item is never asked to open")
    func hiddenStatusItemNeverOpens() {
        var opener = ClipboardProgressMenuAutoOpener()
        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: false) == .none)
    }

    @Test("a status item that becomes reachable can still open for the same paste")
    func openableLaterInTheSamePaste() {
        var opener = ClipboardProgressMenuAutoOpener()
        // The one automatic open is spent only when it actually happens, so a
        // paste that started while the item was crowded out of the menu bar
        // still gets its dropdown once there is room.
        _ = opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: false)
        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("the next paste earns its own automatic open")
    func nextPasteOpensAgain() {
        var opener = ClipboardProgressMenuAutoOpener()
        _ = opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true)
        opener.menuOpened(automatically: true)
        _ = opener.readoutChanged(nil, menuIsOpen: true, canOpen: true)
        opener.menuClosed()

        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("a clear with no paste in flight does nothing")
    func clearWithoutPasteIsInert() {
        var opener = ClipboardProgressMenuAutoOpener()
        #expect(opener.readoutChanged(nil, menuIsOpen: true, canOpen: true) == .none)
    }

    // MARK: - Worth-interrupting gate

    @Test("a transfer that is not a paste never opens the dropdown")
    func nonPasteNeverOpens() {
        var opener = ClipboardProgressMenuAutoOpener()
        #expect(
            opener.readoutChanged(Self.readout(gesture: .paste), menuIsOpen: false, canOpen: true)
                == .none)
    }

    @Test("a non-paste readout does not spend the paste's one open, even in an open menu")
    func nonPasteDoesNotSpendTheOpen() {
        var opener = ClipboardProgressMenuAutoOpener()
        // A preview fetch reveals while the dropdown happens to be open. If that
        // spent the open, a paste following it in the same continuous run of
        // readouts would never get its showing.
        opener.menuOpened(automatically: false)
        #expect(
            opener.readoutChanged(Self.readout(gesture: .paste), menuIsOpen: true, canOpen: true)
                == .none)
        opener.menuClosed()
        #expect(opener.readoutChanged(Self.readout(), menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("a paste that has not been running long enough does not open the dropdown")
    func tooSoonDoesNotOpen() {
        var opener = ClipboardProgressMenuAutoOpener()
        #expect(
            opener.readoutChanged(Self.readout(elapsed: 1.5), menuIsOpen: false, canOpen: true)
                == .none)
    }

    @Test("a paste suppressed for being too young still opens once it has run long enough")
    func youngPasteOpensLater() {
        var opener = ClipboardProgressMenuAutoOpener()
        // Suppression must not spend the open — the readout was never shown.
        _ = opener.readoutChanged(Self.readout(elapsed: 1.5), menuIsOpen: false, canOpen: true)
        #expect(
            opener.readoutChanged(Self.readout(elapsed: 2.5), menuIsOpen: false, canOpen: true)
                == .open)
    }

    @Test("a paste about to finish does not open the dropdown")
    func nearlyDoneDoesNotOpen() {
        var opener = ClipboardProgressMenuAutoOpener()
        #expect(
            opener.readoutChanged(
                Self.readout(secondsRemaining: 1), menuIsOpen: false, canOpen: true) == .none)
    }

    @Test("a paste that turns out slower than its early estimate still earns the open")
    func slowingPasteOpensLater() {
        var opener = ClipboardProgressMenuAutoOpener()
        // The estimate said it was nearly over, so the interruption was withheld;
        // it then slowed down, which is exactly when a standing readout earns its
        // place.
        _ = opener.readoutChanged(
            Self.readout(secondsRemaining: 1), menuIsOpen: false, canOpen: true)
        #expect(
            opener.readoutChanged(
                Self.readout(secondsRemaining: 30), menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("a paste whose bytes are all in does not open the dropdown")
    func allBytesInDoesNotOpen() {
        var opener = ClipboardProgressMenuAutoOpener()
        // `secondsRemaining` reads nil both here and before a rate exists, so the
        // completion check has to come first or this would be taken for "unknown".
        #expect(
            opener.readoutChanged(
                Self.readout(secondsRemaining: nil, bytesTransferred: 1_000, totalBytes: 1_000),
                menuIsOpen: false, canOpen: true) == .none)
    }

    @Test("a paste with no rate estimate yet still opens")
    func unknownRateOpens() {
        var opener = ClipboardProgressMenuAutoOpener()
        // Two seconds in with nothing measurable is a stalled or very slow paste,
        // not one about to finish.
        #expect(
            opener.readoutChanged(
                Self.readout(secondsRemaining: nil), menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("a paste with no byte total to estimate against still opens")
    func zeroTotalOpens() {
        var opener = ClipboardProgressMenuAutoOpener()
        #expect(
            opener.readoutChanged(
                Self.readout(secondsRemaining: nil, bytesTransferred: 0, totalBytes: 0),
                menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("the shipped thresholds hold a short paste back and let a longer one through")
    func shippedThresholds() {
        // Exercises the defaults rather than an injected pair, so the numbers that
        // actually ship are covered.
        #expect(ClipboardProgressMenuAutoOpener.defaultMinimumElapsedToOpen == 2)
        #expect(ClipboardProgressMenuAutoOpener.defaultMinimumRemainingToOpen == 2)

        // The case that prompted the gate: a copy just past the elapsed floor with
        // less than the interruption's own lifetime left to run.
        var tooShort = ClipboardProgressMenuAutoOpener()
        #expect(
            tooShort.readoutChanged(
                Self.readout(elapsed: 2.1, secondsRemaining: 1.4), menuIsOpen: false,
                canOpen: true) == .none)

        var longEnough = ClipboardProgressMenuAutoOpener()
        #expect(
            longEnough.readoutChanged(
                Self.readout(elapsed: 2.1, secondsRemaining: 120), menuIsOpen: false,
                canOpen: true) == .open)
    }
}
