import Testing

@testable import Kernova

/// Unit tests for `AppResidencyController.launchProvenance` and
/// `AppResidencyController.automationIdleOutcome` — what decides that a launch nobody
/// performed stays headless, and what decides whether the resulting process
/// keeps running.
@Suite("AppResidencyController launch provenance", .admissionGated)
struct AppResidencyLaunchProvenanceTests {
    /// The signals an App Intents cold launch presents: no open Apple Event, no
    /// untitled open, no document, and `isDefaultLaunch` false.
    private func automationSignals() -> AppResidencyController.LaunchProvenance {
        AppResidencyController.launchProvenance(
            openedUntitledFile: false,
            openedDocuments: false,
            hasOpenAppleEvent: false,
            isLoginItemLaunch: false,
            isDefaultLaunch: false)
    }

    // MARK: - launchProvenance

    @Test("A launch with no sign of a person asking is automation")
    func noSignalsIsAutomation() {
        #expect(automationSignals() == .automation)
    }

    @Test("A login-item launch outranks every other signal")
    func loginItemWins() {
        for untitled in [true, false] {
            for documents in [true, false] {
                for isDefault in [true, false] {
                    #expect(
                        AppResidencyController.launchProvenance(
                            openedUntitledFile: untitled,
                            openedDocuments: documents,
                            hasOpenAppleEvent: true,
                            isLoginItemLaunch: true,
                            isDefaultLaunch: isDefault) == .loginItem)
                }
            }
        }
    }

    @Test("Any single sign of a person asking resolves to a user launch")
    func anyInteractiveSignalIsUser() {
        #expect(
            AppResidencyController.launchProvenance(
                openedUntitledFile: true, openedDocuments: false, hasOpenAppleEvent: false,
                isLoginItemLaunch: false, isDefaultLaunch: false) == .user)
        #expect(
            AppResidencyController.launchProvenance(
                openedUntitledFile: false, openedDocuments: true, hasOpenAppleEvent: false,
                isLoginItemLaunch: false, isDefaultLaunch: false) == .user)
        #expect(
            AppResidencyController.launchProvenance(
                openedUntitledFile: false, openedDocuments: false, hasOpenAppleEvent: true,
                isLoginItemLaunch: false, isDefaultLaunch: false) == .user)
        #expect(
            AppResidencyController.launchProvenance(
                openedUntitledFile: false, openedDocuments: false, hasOpenAppleEvent: false,
                isLoginItemLaunch: false, isDefaultLaunch: true) == .user)
    }

    @Test("Automation is the only combination of the four that is not a user launch")
    func automationIsTheSoleHeadlessCombination() {
        var headless = 0
        for untitled in [true, false] {
            for documents in [true, false] {
                for openEvent in [true, false] {
                    for isDefault in [true, false] {
                        let provenance = AppResidencyController.launchProvenance(
                            openedUntitledFile: untitled,
                            openedDocuments: documents,
                            hasOpenAppleEvent: openEvent,
                            isLoginItemLaunch: false,
                            isDefaultLaunch: isDefault)
                        if provenance == .automation { headless += 1 }
                    }
                }
            }
        }
        #expect(headless == 1)
    }

    @Test("An ordinary Launch Services open presents, foregrounded or not")
    func launchServicesOpenIsUser() {
        // Both `open <app>` and `open -g -j <app>` measured identically:
        // `kAEOpenApplication`, an untitled open, and a default launch.
        #expect(
            AppResidencyController.launchProvenance(
                openedUntitledFile: true, openedDocuments: false, hasOpenAppleEvent: true,
                isLoginItemLaunch: false, isDefaultLaunch: true) == .user)
    }

    @Test("A document launch presents even though it is not a default launch")
    func documentLaunchIsUser() {
        #expect(
            AppResidencyController.launchProvenance(
                openedUntitledFile: false, openedDocuments: true, hasOpenAppleEvent: true,
                isLoginItemLaunch: false, isDefaultLaunch: false) == .user)
    }

    // MARK: - automationIdleOutcome

    /// The settled automation launch: headless, nothing running, residency off.
    private func idleOutcome(
        isAutomationLaunch: Bool = true,
        hasPresentedInterface: Bool = false,
        hasVisibleUserWindow: Bool = false,
        keepInMenuBar: Bool = false,
        hasUninterruptibleWork: Bool = false,
        hasLiveGuest: Bool = false,
        hasIntentInFlight: Bool = false
    ) -> AppResidencyController.AutomationIdleOutcome {
        AppResidencyController.automationIdleOutcome(
            isAutomationLaunch: isAutomationLaunch,
            hasPresentedInterface: hasPresentedInterface,
            hasVisibleUserWindow: hasVisibleUserWindow,
            keepInMenuBar: keepInMenuBar,
            hasUninterruptibleWork: hasUninterruptibleWork,
            hasLiveGuest: hasLiveGuest,
            hasIntentInFlight: hasIntentInFlight)
    }

    @Test("A headless automation launch with nothing left to run and no status item quits")
    func unreachableAndIdleQuits() {
        #expect(idleOutcome() == .quit)
    }

    @Test("Residency keeps the process, because the status item makes it reachable")
    func residencyStaysResident() {
        #expect(idleOutcome(keepInMenuBar: true) == .stayResident)
    }

    @Test("A live guest holds the process whatever the residency preference")
    func liveGuestHolds() {
        #expect(idleOutcome(hasLiveGuest: true) == .stayResident)
        #expect(idleOutcome(keepInMenuBar: true, hasLiveGuest: true) == .stayResident)
    }

    @Test("Work in flight holds the process")
    func uninterruptibleWorkHolds() {
        #expect(idleOutcome(hasUninterruptibleWork: true) == .stayResident)
    }

    @Test("A launch a person performed is never this decision's to make")
    func interactiveLaunchIsNeverQuit() {
        #expect(idleOutcome(isAutomationLaunch: false) == .stayResident)
    }

    @Test("Once the GUI has been summoned the window reconcile owns the process")
    func presentedProcessHandsBack() {
        #expect(idleOutcome(hasPresentedInterface: true) == .stayResident)
    }

    @Test("A window on screen holds the process even before anything marks it presented")
    func visibleWindowHolds() {
        #expect(idleOutcome(hasVisibleUserWindow: true) == .stayResident)
    }

    @Test("An intent still running holds the process, whatever else is settled")
    func intentInFlightHolds() {
        // The decision has three triggers and only the gateway's idle report
        // knows an intent is running, so in-flight state has to be a condition
        // of the answer rather than merely the reason it was asked.
        #expect(idleOutcome(hasIntentInFlight: true) == .stayResident)
    }

    @Test("The library read landing mid-intent cannot quit the process it launched")
    func libraryReadDuringFirstIntentHolds() {
        // `observeForTermination` is armed before the library read populates
        // `instances`, so it wakes while the launching intent is still awaiting
        // readiness: no guest yet, no work yet, and residency off.
        #expect(
            idleOutcome(keepInMenuBar: false, hasLiveGuest: false, hasIntentInFlight: true)
                == .stayResident)
    }
}
