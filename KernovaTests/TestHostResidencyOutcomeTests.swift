import Testing

@testable import Kernova

/// Unit tests for `TestHostResidencyController.idleOutcome` — the one decision
/// behind both the test host's window reconcile and its answer to AppKit's
/// last-window rule.
@Suite("TestHostResidencyController idle outcome", .admissionGated)
struct TestHostResidencyOutcomeTests {
    private func outcome(
        hasVisibleUserWindow: Bool = false,
        isHidden: Bool = false,
        hasLiveGuest: Bool = false
    ) -> TestHostResidencyController.IdleOutcome {
        TestHostResidencyController.idleOutcome(
            hasVisibleUserWindow: hasVisibleUserWindow,
            isHidden: isHidden,
            hasLiveGuest: hasLiveGuest)
    }

    @Test("a window on screen holds the process", arguments: [true, false])
    func visibleWindowStaysResident(hasLiveGuest: Bool) {
        // `hasUserWindow` counts Settings, a miniaturized window and an
        // untracked AppKit panel, so none of them can be idle-quit away.
        #expect(
            outcome(hasVisibleUserWindow: true, hasLiveGuest: hasLiveGuest) == .stayResident)
    }

    @Test("a hidden app holds the process")
    func hiddenStaysResident() {
        // ⌘H turns `isVisible` false for every window without closing any, so
        // without this term a hidden test host would quit on the next change in
        // guest liveness.
        #expect(outcome(isHidden: true) == .stayResident)
    }

    @Test("a live guest holds the process")
    func liveGuestStaysResident() {
        #expect(outcome(hasLiveGuest: true) == .stayResident)
    }

    @Test("no window, not hidden, and no live guest quits")
    func nothingLeftQuits() {
        #expect(outcome() == .quit)
    }
}
