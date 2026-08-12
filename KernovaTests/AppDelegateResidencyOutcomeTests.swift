import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.residencyOutcome` — what the window reconcile does
/// once the last window closes (#793).
@Suite("AppDelegate residency outcome")
struct AppDelegateResidencyOutcomeTests {
    @Test("a window on screen always keeps the Dock icon", arguments: [true, false])
    func windowOnScreenShowsDockIcon(keepInMenuBar: Bool) {
        #expect(
            AppDelegate.residencyOutcome(
                hasVisibleUserWindow: true,
                keepInMenuBar: keepInMenuBar,
                hasPreparingInstance: false) == .showDockIcon)
    }

    @Test("the last window closing with the toggle on goes headless")
    func lastWindowWithKeepOnGoesHeadless() {
        #expect(
            AppDelegate.residencyOutcome(
                hasVisibleUserWindow: false,
                keepInMenuBar: true,
                hasPreparingInstance: false) == .goHeadless)
    }

    @Test("the last window closing with the toggle off quits")
    func lastWindowWithKeepOffQuits() {
        #expect(
            AppDelegate.residencyOutcome(
                hasVisibleUserWindow: false,
                keepInMenuBar: false,
                hasPreparingInstance: false) == .quit)
    }

    @Test("a preparing instance vetoes the quit")
    func preparingInstanceBlocksTheQuit() {
        // The quit path trashes partial bundles, so an ordinary window close must
        // not destroy an in-flight import.
        #expect(
            AppDelegate.residencyOutcome(
                hasVisibleUserWindow: false,
                keepInMenuBar: false,
                hasPreparingInstance: true) == .goHeadless)
    }

    @Test("a preparing instance changes nothing while the toggle is on")
    func preparingInstanceIsIrrelevantWhenKeepingInMenuBar() {
        #expect(
            AppDelegate.residencyOutcome(
                hasVisibleUserWindow: false,
                keepInMenuBar: true,
                hasPreparingInstance: true) == .goHeadless)
    }
}
