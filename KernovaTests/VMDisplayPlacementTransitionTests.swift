import Testing

@testable import Kernova

/// Unit tests for `VMDisplayPlacementController.placement(for:)` — the matrix
/// that decides where each display transition leaves the VM, which preference
/// it persists, and what the app owes afterwards.
///
/// The `nil` persisted preference is the load-bearing case: an open persisted
/// the user's choice at the request site, and a close that is not a pop-in must
/// leave `.fullscreen` intact so the next reopen restores it.
@Suite("VMDisplayPlacementController.placement", .admissionGated)
struct VMDisplayPlacementTransitionTests {
    @Test("Showing a pop-out window hosts the display in a window, persisting nothing")
    func shownPopOut() {
        let placement = VMDisplayPlacementController.placement(for: .shown(fullscreen: false))
        #expect(placement.mode == .popOut)
        #expect(placement.persistPreference == nil)
        #expect(placement.followUp == .none)
    }

    @Test("Showing a fullscreen window hosts the display fullscreen, persisting nothing")
    func shownFullscreen() {
        let placement = VMDisplayPlacementController.placement(for: .shown(fullscreen: true))
        #expect(placement.mode == .fullscreen)
        #expect(placement.persistPreference == nil)
        #expect(placement.followUp == .none)
    }

    @Test("Entering fullscreen persists the fullscreen preference")
    func enteredFullscreen() {
        let placement = VMDisplayPlacementController.placement(for: .enteredFullscreen)
        #expect(placement.mode == .fullscreen)
        #expect(placement.persistPreference == .fullscreen)
        #expect(placement.followUp == .none)
    }

    @Test("Exiting fullscreen persists the pop-out preference")
    func exitedFullscreen() {
        let placement = VMDisplayPlacementController.placement(for: .exitedFullscreen)
        #expect(placement.mode == .popOut)
        #expect(placement.persistPreference == .popOut)
        #expect(placement.followUp == .none)
    }

    @Test("A user close leaves the VM headless with its preference intact")
    func userClose() {
        let placement = VMDisplayPlacementController.placement(for: .closed(.userClose))
        #expect(placement.mode == .hidden)
        #expect(placement.persistPreference == nil)
        #expect(placement.followUp == .none)
    }

    @Test("An app dismissal returns the display slot and reconciles idleness")
    func appDismissal() {
        let placement = VMDisplayPlacementController.placement(for: .closed(.appDismissal))
        #expect(placement.mode == .inline)
        #expect(placement.persistPreference == nil)
        #expect(placement.followUp == .idleReconcile)
    }

    @Test("A pop-in returns the display slot, persists inline, and restores the library")
    func popIn() {
        let placement = VMDisplayPlacementController.placement(for: .closed(.popIn))
        #expect(placement.mode == .inline)
        #expect(placement.persistPreference == .inline)
        #expect(placement.followUp == .restoreLibrary)
    }
}
