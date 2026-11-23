import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Unit tests for `AppResidencyPolicy.residencyOutcome` — what the window reconcile does
/// once no window is on screen (#793).
@Suite("AppResidencyPolicy residency outcome", .caseScoped)
struct AppResidencyOutcomeTests {
    private func outcome(
        hasVisibleUserWindow: Bool = false,
        isHidden: Bool = false,
        keepInMenuBar: Bool = false,
        hasUninterruptibleWork: Bool = false
    ) -> AppResidencyPolicy.ResidencyOutcome {
        AppResidencyPolicy.residencyOutcome(
            hasVisibleUserWindow: hasVisibleUserWindow,
            isHidden: isHidden,
            keepInMenuBar: keepInMenuBar,
            hasUninterruptibleWork: hasUninterruptibleWork)
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
}
