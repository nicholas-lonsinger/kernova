import Cocoa
import os

/// The unit-test host's residency: a plain foreground app that shows the library
/// at launch and leaves once the last VM a suite started stops.
///
/// Constructed only by `AppDelegate.main()`'s test-host arm, under XCTest, so
/// none of the resident-app machinery — status item, activation-policy
/// switching, login-item registration, the App Intents front door — is reached
/// through this one.
///
/// The process is `.regular` throughout, which is what leaves
/// ``prepareToPresentWindow()`` and ``syncActivationPolicy()`` with nothing to
/// do, and leaves ``idleOutcome(hasVisibleUserWindow:isHidden:hasLiveGuest:)``
/// as the only decision this makes.
///
/// That decision needs no counterpart to ``AppResidencyController``'s
/// `hasPresentedInterface` latch: ``start(provenance:)`` puts the library on
/// screen synchronously *before* arming the observation, so no reconcile can
/// ever fire against a window-less process.
@MainActor
final class TestHostResidencyController: AppResidencyHosting {
    private let viewModel: VMLibraryViewModel
    /// The one owner of which user-facing windows exist, which answers the window
    /// half of the idle decision.
    private let windows: AppWindowRegistry
    weak var host: (any AppLaunchHosting)?

    /// Watches guest liveness so the test host settles once the last VM stops.
    private var idleTerminationObservation: ObservationLoop?

    /// Set in ``noteWillBecomeActive()`` and read in
    /// ``handleReopen(hasVisibleWindows:)`` to distinguish a dock click that
    /// activates the app from one on an already-active app.
    ///
    /// Cleared synchronously in ``handleReopen(hasVisibleWindows:)`` as well as
    /// asynchronously, so rapid successive dock clicks can't read a stale `true`
    /// before the async clear runs.
    private var wasJustActivated = false

    private static let logger = Logger(subsystem: "app.kernova", category: "TestHostResidency")

    init(viewModel: VMLibraryViewModel, windows: AppWindowRegistry) {
        self.viewModel = viewModel
        self.windows = windows
    }

    // MARK: - Start

    /// Shows the library, then arms the idle quit.
    ///
    /// The provenance is ignored: XCTest launches this process one way, and the
    /// library goes up for it.
    func start(provenance: AppResidencyController.LaunchProvenance) {
        windows.showLibrary(bringToFront: true)
        idleTerminationObservation = observeGuestLiveness(of: viewModel) { [weak self] in
            self?.reconcileIdleTermination()
        }
    }

    /// Nothing to publish: the gateway rebuilds Siri's parameter vocabulary,
    /// which writes to the developer's own Shortcuts database, and holds an
    /// events subscription that would keep the core's observation loop armed for
    /// every test.
    func registerIntentGateway() {}

    // MARK: - Residency

    /// Nothing to prepare: this is a plain foreground `.regular` app, so a window
    /// can always go on screen as-is.
    func prepareToPresentWindow() {}

    /// Nothing to sync: this is a plain foreground `.regular` app, and stays one.
    func syncActivationPolicy() {}

    /// No headless state to downgrade a quit into, which is what makes every quit
    /// in the test host a real one — see
    /// ``AppTerminationController/shouldTerminateOnQuit``.
    var softQuit: (any SoftQuitHosting)? { nil }

    // MARK: - Activation and Reopen

    func noteWillBecomeActive() {
        Self.logger.debug("applicationWillBecomeActive: setting wasJustActivated")
        wasJustActivated = true
        // Clear after the current event cycle so the flag doesn't go stale for
        // non-dock activations (Cmd-Tab, clicking a window), where
        // `applicationShouldHandleReopen` is never called.
        Task { @MainActor [weak self] in
            self?.wasJustActivated = false
        }
    }

    func handleReopen(hasVisibleWindows flag: Bool) {
        let justActivated = wasJustActivated
        wasJustActivated = false  // Synchronous clear — see wasJustActivated doc comment

        if !flag {
            windows.showLibrary(bringToFront: true)
        } else if !justActivated && windows.isLibraryDismissed {
            Self.logger.debug("applicationShouldHandleReopen: reopening dismissed library window")
            windows.showLibrary(bringToFront: true)
        } else if justActivated {
            Self.logger.debug(
                "applicationShouldHandleReopen: suppressed (initial activation with visible windows)"
            )
        }
    }

    /// Nothing to present: the test host manages its own window, and every caller
    /// of this is a resident-app path (a status-item summon, a Finder document
    /// open) that has no counterpart here.
    func presentSummonedInterface() {}

    /// Nothing to summon, for the same reason as ``presentSummonedInterface()``.
    func summonUserInterface() {}

    // MARK: - Idle Termination

    /// What becomes of the test host once a window closes or a guest settles.
    enum IdleOutcome: Equatable {
        /// Keep running — a window is on screen, the app is hidden, or a guest is
        /// still live.
        case stayResident
        /// Quit through `applicationShouldTerminate`, save-suspending anything live.
        case quit
    }

    /// Decides whether the test host still has a reason to run.
    ///
    /// `isHidden` is a term of its own because
    /// ``AppWindowRegistry/hasUserWindow(countingMiniaturized:)`` deliberately
    /// ignores `NSApp.isHidden` and reads `isVisible`, which ⌘H turns false for
    /// every window without closing any — so without it, ⌘H plus any change in
    /// guest liveness would quit the process out from under its windows.
    nonisolated static func idleOutcome(
        hasVisibleUserWindow: Bool, isHidden: Bool, hasLiveGuest: Bool
    ) -> IdleOutcome {
        if hasVisibleUserWindow || isHidden || hasLiveGuest { return .stayResident }
        return .quit
    }

    /// The idle decision read from live state.
    private var currentIdleOutcome: IdleOutcome {
        Self.idleOutcome(
            hasVisibleUserWindow: windows.hasUserWindow(countingMiniaturized: true),
            isHidden: NSApp.isHidden,
            hasLiveGuest: viewModel.instances.contains(where: \.isKeepingAppAlive))
    }

    func reconcileIdleTermination() {
        switch currentIdleOutcome {
        case .stayResident:
            break
        case .quit:
            Self.logger.notice("No visible windows and no active VMs — requesting termination")
            NSApp.terminate(nil)
        }
    }

    /// The same idle decision AppKit's last-window rule asks for, so the two can
    /// never disagree — AppKit only asks once every window has closed, which the
    /// window term already covers.
    var terminatesAfterLastWindowClosed: Bool { currentIdleOutcome == .quit }
}
