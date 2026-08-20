import Testing

@testable import KernovaKit

/// Unit tests for the gate every automatic status-item open passes through —
/// the readout's own and the staged-line reveal a refusal raises.
@Suite("ClipboardProgressStatusItemPresenter.allowsAutomaticOpen", .admissionGated)
struct ClipboardProgressStatusItemPresenterTests {
    private func allows(visible: Bool, onScreen: Bool, menuOpen: Bool) -> Bool {
        ClipboardProgressStatusItemPresenter.allowsAutomaticOpen(
            isVisible: visible, isOnScreen: onScreen, menuIsOpen: menuOpen)
    }

    @Test("an on-screen item with no dropdown up may open")
    func opensWhenOnScreenAndClosed() {
        #expect(allows(visible: true, onScreen: true, menuOpen: false))
    }

    @Test("an already-open dropdown is never clicked — the click toggles it closed")
    func neverTogglesAnOpenDropdown() {
        // The whole point of the gate: `performClick` on an open dropdown
        // dismisses it, and a dropdown that opened before the line was staged
        // does not contain that line anyway.
        #expect(!allows(visible: true, onScreen: true, menuOpen: true))
    }

    @Test("an item the app hid, or one no screen shows, is not clicked")
    func requiresAVisibleOnScreenItem() {
        #expect(!allows(visible: false, onScreen: true, menuOpen: false))
        #expect(!allows(visible: true, onScreen: false, menuOpen: false))
        #expect(!allows(visible: false, onScreen: false, menuOpen: false))
    }
}
