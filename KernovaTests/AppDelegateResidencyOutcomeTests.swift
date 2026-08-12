import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.residencyOutcome` — what the window reconcile does
/// once no window is on screen (#793).
@Suite("AppDelegate residency outcome")
struct AppDelegateResidencyOutcomeTests {
    private func outcome(
        hasVisibleUserWindow: Bool = false,
        isHidden: Bool = false,
        keepInMenuBar: Bool = false,
        hasUninterruptibleWork: Bool = false
    ) -> AppDelegate.ResidencyOutcome {
        AppDelegate.residencyOutcome(
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

    @Test("a hidden app never quits, whatever the toggle says", arguments: [true, false])
    func hiddenAppNeverQuits(keepInMenuBar: Bool) {
        // ⌘H makes every window report `isVisible == false` without closing any,
        // so a background close landing mid-hide must not read as "no windows
        // left" and discard windows the user never closed.
        #expect(outcome(isHidden: true, keepInMenuBar: keepInMenuBar) == .goHeadless)
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
