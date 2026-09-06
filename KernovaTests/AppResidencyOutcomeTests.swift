import Testing

@testable import Kernova

/// Unit tests for `AppResidencyController.residencyOutcome` — what the window reconcile does
/// once no window is on screen (#793).
@Suite("AppResidencyController residency outcome", .admissionGated)
struct AppResidencyOutcomeTests {
    private func outcome(
        hasVisibleUserWindow: Bool = false,
        isHidden: Bool = false,
        keepInMenuBar: Bool = false,
        hasUninterruptibleWork: Bool = false
    ) -> AppResidencyController.ResidencyOutcome {
        AppResidencyController.residencyOutcome(
            hasVisibleUserWindow: hasVisibleUserWindow,
            isHidden: isHidden,
            keepInMenuBar: keepInMenuBar,
            hasUninterruptibleWork: hasUninterruptibleWork)
    }

    @Test("a window on screen always keeps the Dock icon", arguments: [true, false])
    func windowOnScreenShowsDockIcon(keepInMenuBar: Bool) {
        #expect(outcome(hasVisibleUserWindow: true, keepInMenuBar: keepInMenuBar) == .showDockIcon)
    }

    @Test("the last window closing with the toggle on goes headless")
    func lastWindowWithKeepOnGoesHeadless() {
        #expect(outcome(keepInMenuBar: true) == .goHeadless)
    }

    @Test("the last window closing with the toggle off quits")
    func lastWindowWithKeepOffQuits() {
        #expect(outcome() == .quit)
    }

    // MARK: - Hiding

    @Test("a hidden app is left as it is, whatever the toggle says", arguments: [true, false])
    func hiddenAppWaitsForUnhide(keepInMenuBar: Bool) {
        // ⌘H makes every window report `isVisible == false` without closing any,
        // so the windows a hidden app has are ones this cannot see: it decides
        // nothing, leaving a presented app its Dock icon and a headless one its
        // absence until the unhide reconcile can read the windows.
        #expect(outcome(isHidden: true, keepInMenuBar: keepInMenuBar) == .waitForUnhide)
    }

    @Test("a window on screen outranks a hide", arguments: [true, false])
    func hiddenWithAVisibleWindowShowsDockIcon(keepInMenuBar: Bool) {
        // ⌘H leaves a miniaturized window miniaturized, and the reconcile counts
        // one as present — so the window term is answerable even while hidden.
        #expect(
            outcome(hasVisibleUserWindow: true, isHidden: true, keepInMenuBar: keepInMenuBar)
                == .showDockIcon)
    }

    @Test("work in flight does not lift the hide's hold")
    func hiddenWithWorkInFlightWaitsForUnhide() {
        #expect(outcome(isHidden: true, hasUninterruptibleWork: true) == .waitForUnhide)
    }

    // MARK: - Work in flight

    @Test("work in flight holds the quit and keeps the app reachable")
    func uninterruptibleWorkKeepsTheDockIcon() {
        // Not `.goHeadless`: with the toggle off there is no status item, so
        // demoting would hide the progress the hold exists to protect.
        #expect(outcome(hasUninterruptibleWork: true) == .showDockIcon)
    }

    @Test("work in flight changes nothing while the toggle is on")
    func uninterruptibleWorkIsIrrelevantWhenKeepingInMenuBar() {
        #expect(outcome(keepInMenuBar: true, hasUninterruptibleWork: true) == .goHeadless)
    }
}
