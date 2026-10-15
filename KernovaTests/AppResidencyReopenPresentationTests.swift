import Testing

@testable import Kernova

/// Unit tests for
/// `AppResidencyController.reopenPresentation(hasVisibleUserWindow:)` —
/// the pure helper that decides what a reopen (a Dock click, `open`) does to
/// the GUI.
///
/// A reopen with a user window — a miniaturized one included — must present
/// nothing: that window owns the presentation, and re-presenting the library
/// would drag it forward over a per-VM display or clipboard window the status
/// item opened alone.
@Suite("AppResidencyController.reopenPresentation", .caseScoped)
struct AppResidencyReopenPresentationTests {
    @Test("A reopen with a user window presents nothing")
    func userWindowPresentsNothing() {
        #expect(AppResidencyController.reopenPresentation(hasVisibleUserWindow: true) == .nothing)
    }

    @Test("A reopen with no user window presents the library")
    func noUserWindowPresentsLibrary() {
        #expect(AppResidencyController.reopenPresentation(hasVisibleUserWindow: false) == .library)
    }
}
