import Cocoa
import Testing

@testable import Kernova

/// Unit tests for the pure cold-launch decisions (#460).
///
/// `AppDelegate.launchProvenance(eventID:launchPropData:)` classifies the launch
/// Apple event — a login-item launch carries `keyAELaunchedAsLogInItem`, a plain
/// `oapp` is a manual launch, and anything unreadable falls back to the
/// activation heuristic. `AppDelegate.coldLaunchOutcome(showWindow:alreadyResolved:)`
/// latches the resolution so later ordinary activations don't re-trigger it. The
/// AppKit timing itself is verified manually.
@Suite("AppDelegate cold-launch decisions")
struct AppDelegateColdLaunchTests {
    // MARK: - launchProvenance

    @Test("an oapp event with the login-item property classifies as a login launch")
    func loginItemEventClassifiesLoginItem() {
        #expect(
            AppDelegate.launchProvenance(
                eventID: AEEventID(kAEOpenApplication),
                launchPropData: OSType(keyAELaunchedAsLogInItem))
                == .loginItem)
    }

    @Test("a plain oapp event classifies as a manual launch")
    func plainOpenEventClassifiesManual() {
        #expect(
            AppDelegate.launchProvenance(
                eventID: AEEventID(kAEOpenApplication), launchPropData: nil)
                == .manual)
    }

    @Test("an oapp event with an unrelated property value classifies as manual")
    func unrelatedPropDataClassifiesManual() {
        #expect(
            AppDelegate.launchProvenance(
                eventID: AEEventID(kAEOpenApplication), launchPropData: 0)
                == .manual)
    }

    @Test("a non-oapp event is indeterminate (heuristic fallback)")
    func nonOpenEventIsIndeterminate() {
        #expect(
            AppDelegate.launchProvenance(
                eventID: AEEventID(kAEOpenDocuments),
                launchPropData: OSType(keyAELaunchedAsLogInItem))
                == .indeterminate)
    }

    @Test("a missing launch event is indeterminate (heuristic fallback)")
    func missingEventIsIndeterminate() {
        #expect(
            AppDelegate.launchProvenance(eventID: nil, launchPropData: nil)
                == .indeterminate)
    }

    // MARK: - coldLaunchOutcome

    @Test("first resolution with a show signal shows the window (manual launch)")
    func showSignalShowsWindow() {
        #expect(
            AppDelegate.coldLaunchOutcome(showWindow: true, alreadyResolved: false)
                == .showWindow)
    }

    @Test("first resolution without a show signal stays headless (login launch)")
    func noShowSignalStaysHeadless() {
        #expect(
            AppDelegate.coldLaunchOutcome(showWindow: false, alreadyResolved: false)
                == .stayHeadless)
    }

    @Test("once resolved, a later activation is ignored")
    func resolvedIgnoresActivation() {
        #expect(
            AppDelegate.coldLaunchOutcome(showWindow: true, alreadyResolved: true)
                == .alreadyResolved)
    }

    @Test("once resolved, the settle-window fallback is ignored")
    func resolvedIgnoresFallback() {
        #expect(
            AppDelegate.coldLaunchOutcome(showWindow: false, alreadyResolved: true)
                == .alreadyResolved)
    }
}
