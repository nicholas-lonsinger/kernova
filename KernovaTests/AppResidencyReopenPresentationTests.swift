import KernovaTestSupport
import Testing

@testable import Kernova

/// Unit tests for
/// `AppResidencyController.reopenPresentation(hasOnScreenUserWindow:)` —
/// the pure helper that decides what a reopen (a Dock click, `open`) does to
/// the GUI.
///
/// A reopen with a window already on screen must present nothing: that window
/// owns the presentation, and re-presenting the library would drag it forward
/// over a per-VM display or clipboard window the status item opened alone.
@Suite("AppResidencyController.reopenPresentation", .admissionGated)
struct AppResidencyReopenPresentationTests {
    @Test("A reopen with a window already on screen presents nothing")
    func windowOnScreenPresentsNothing() {
        #expect(AppResidencyController.reopenPresentation(hasOnScreenUserWindow: true) == .nothing)
    }

    @Test("A reopen with no window on screen presents the library")
    func noWindowOnScreenPresentsLibrary() {
        #expect(AppResidencyController.reopenPresentation(hasOnScreenUserWindow: false) == .library)
    }
}
