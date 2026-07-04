import Testing

@testable import Kernova

/// Unit tests for the pure cold-launch activation decision (#460).
///
/// `AppDelegate.coldLaunchOutcome(didBecomeActive:alreadyResolved:)`: a manual
/// launch activates the app (→ show the window); a login launch never activates
/// during the settle window (→ stay headless); and once resolved the decision is
/// inert so later ordinary activations don't re-trigger it. The AppKit timing
/// itself is verified manually.
@Suite("AppDelegate.coldLaunchOutcome")
struct AppDelegateColdLaunchTests {
    @Test("first resolution with activation shows the window (manual launch)")
    func activatedShowsWindow() {
        #expect(
            AppDelegate.coldLaunchOutcome(didBecomeActive: true, alreadyResolved: false)
                == .showWindow)
    }

    @Test("first resolution without activation stays headless (login launch)")
    func notActivatedStaysHeadless() {
        #expect(
            AppDelegate.coldLaunchOutcome(didBecomeActive: false, alreadyResolved: false)
                == .stayHeadless)
    }

    @Test("once resolved, a later activation is ignored")
    func resolvedIgnoresActivation() {
        #expect(
            AppDelegate.coldLaunchOutcome(didBecomeActive: true, alreadyResolved: true)
                == .alreadyResolved)
    }

    @Test("once resolved, the settle-window fallback is ignored")
    func resolvedIgnoresFallback() {
        #expect(
            AppDelegate.coldLaunchOutcome(didBecomeActive: false, alreadyResolved: true)
                == .alreadyResolved)
    }
}
