import Cocoa

/// The unit-test host's residency: a plain foreground app that presents nothing
/// of its own and never ends itself — XCTest owns the process's lifetime.
///
/// Constructed only by `AppDelegate.main()`'s test-host arm, under XCTest, so
/// none of the resident-app machinery — status item, activation-policy
/// switching, login-item registration, the App Intents front door — is reached
/// through this one.
@MainActor
final class TestHostResidencyController: AppResidencyHosting {
    weak var host: (any AppLaunchHosting)?

    // MARK: - Start

    /// Nothing to bring up: a window of the test host's own would sit on the
    /// developer's screen for the whole run, and every window a test needs, the
    /// test creates.
    func start(provenance: AppResidencyController.LaunchProvenance) {}

    /// Nothing to open: the gateway writes to the developer's own Spotlight
    /// index and holds an events subscription that would keep the core's
    /// observation loop armed for every test, and a bound command socket would
    /// put the test host in front of any `kernova` the developer ran meanwhile.
    func registerAutomationFrontDoors() {}

    /// Nothing to answer: the test host registers no URL scheme, so no link is
    /// ever delivered to it.
    func openAutomationLink(_ url: URL) {}

    /// No door, for the reason ``registerAutomationFrontDoors()`` states: the
    /// test host opens none, so a script has nothing here to address.
    var scriptingGateway: VMScriptingGateway? { nil }

    // MARK: - Residency

    /// Nothing to prepare: this is a plain foreground `.regular` app, so a window
    /// can always go on screen as-is.
    func prepareToPresentWindow() {}

    /// Nothing to sync: this is a plain foreground `.regular` app, and stays one.
    func syncActivationPolicy() {}

    /// Never absent: this is a plain foreground `.regular` app, so only its own
    /// activation is left to read.
    var guiPosture: GUIPosture { NSApp.isActive ? .foreground : .background }

    /// No headless state to downgrade a quit into, which is what makes every quit
    /// in the test host a real one — see
    /// ``AppTerminationController/shouldTerminateOnQuit``.
    var softQuit: (any SoftQuitHosting)? { nil }

    // MARK: - Unhide and Reopen

    /// Nothing to reconcile: the process is `.regular` throughout, and nothing
    /// here decides by what is on screen.
    func noteDidUnhide() {}

    /// Nothing to reopen: the test host has no interface of its own to bring
    /// back.
    func handleReopen(hasVisibleWindows: Bool) {}

    /// Nothing to present: every caller of this is a resident-app path (a
    /// status-item summon, a Finder document open) that has no counterpart here.
    func presentSummonedInterface() {}

    /// Nothing to summon, for the same reason as ``presentSummonedInterface()``.
    func summonUserInterface() {}
}
