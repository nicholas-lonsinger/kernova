import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `PasteProgressMenuAutoOpener` — the rules that let a
/// materializing paste open the status-item dropdown by itself, once (#643).
@Suite("PasteProgressMenuAutoOpener")
struct PasteProgressMenuAutoOpenerTests {
    @Test("a paste's first readout opens the dropdown")
    func firstReadoutOpens() {
        var opener = PasteProgressMenuAutoOpener()
        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("later updates in the same paste never re-open")
    func laterUpdatesDoNotReopen() {
        var opener = PasteProgressMenuAutoOpener()
        _ = opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true)
        opener.menuOpened(automatically: true)
        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: true, canOpen: true) == .none)
    }

    @Test("a dropdown the user dismissed stays closed for the rest of the paste")
    func userDismissalIsFinalForThePaste() {
        var opener = PasteProgressMenuAutoOpener()
        _ = opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true)
        opener.menuOpened(automatically: true)
        opener.menuClosed()

        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true) == .none)
    }

    @Test("the paste closes only the dropdown it opened")
    func closesOnlyItsOwnDropdown() {
        var opener = PasteProgressMenuAutoOpener()
        _ = opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true)
        opener.menuOpened(automatically: true)

        #expect(
            opener.readoutChanged(hasReadout: false, menuIsOpen: true, canOpen: true) == .close)
    }

    @Test("a dropdown the user opened is left alone when the paste ends")
    func leavesAUserOpenedDropdownAlone() {
        var opener = PasteProgressMenuAutoOpener()
        _ = opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true)
        // The user got there first — this is their dropdown, not the paste's.
        opener.menuOpened(automatically: false)

        #expect(
            opener.readoutChanged(hasReadout: false, menuIsOpen: true, canOpen: true) == .none)
    }

    @Test("a readout appearing while the dropdown is already open opens nothing")
    func alreadyOpenNeedsNoOpen() {
        var opener = PasteProgressMenuAutoOpener()
        opener.menuOpened(automatically: false)
        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: true, canOpen: true) == .none)
    }

    @Test("closing a dropdown the readout appeared inside does not make it pop back open")
    func dismissingADropdownTheReadoutAppearedInIsFinal() {
        var opener = PasteProgressMenuAutoOpener()
        // The user opened the dropdown for their own reasons, and the paste's
        // readout then revealed into it — so the paste has had its showing even
        // though it never asked for the open.
        opener.menuOpened(automatically: false)
        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: true, canOpen: true) == .none)

        opener.menuClosed()
        // Dismissing it is the user saying no. The next throttled update must not
        // answer that by popping the dropdown straight back up.
        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true) == .none)
    }

    @Test("an off-screen status item is never asked to open")
    func hiddenStatusItemNeverOpens() {
        var opener = PasteProgressMenuAutoOpener()
        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: false) == .none)
    }

    @Test("a status item that becomes reachable can still open for the same paste")
    func openableLaterInTheSamePaste() {
        var opener = PasteProgressMenuAutoOpener()
        // The one automatic open is spent only when it actually happens, so a
        // paste that started while the item was crowded out of the menu bar
        // still gets its dropdown once there is room.
        _ = opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: false)
        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("the next paste earns its own automatic open")
    func nextPasteOpensAgain() {
        var opener = PasteProgressMenuAutoOpener()
        _ = opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true)
        opener.menuOpened(automatically: true)
        _ = opener.readoutChanged(hasReadout: false, menuIsOpen: true, canOpen: true)
        opener.menuClosed()

        #expect(
            opener.readoutChanged(hasReadout: true, menuIsOpen: false, canOpen: true) == .open)
    }

    @Test("a clear with no paste in flight does nothing")
    func clearWithoutPasteIsInert() {
        var opener = PasteProgressMenuAutoOpener()
        #expect(
            opener.readoutChanged(hasReadout: false, menuIsOpen: true, canOpen: true) == .none)
    }
}
