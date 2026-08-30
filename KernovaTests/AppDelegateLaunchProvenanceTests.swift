import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.launchProvenance` and
/// `AppDelegate.automationIdleOutcome` — what decides that a launch nobody
/// performed stays headless, and what decides whether the resulting process
/// keeps running.
@Suite("AppDelegate launch provenance", .admissionGated)
struct AppDelegateLaunchProvenanceTests {
    /// The signals an App Intents cold launch presents: no open Apple Event, no
    /// untitled open, no document, and `isDefaultLaunch` false.
    private func automationSignals() -> AppDelegate.LaunchProvenance {
        AppDelegate.launchProvenance(
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
                        AppDelegate.launchProvenance(
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
            AppDelegate.launchProvenance(
                openedUntitledFile: true, openedDocuments: false, hasOpenAppleEvent: false,
                isLoginItemLaunch: false, isDefaultLaunch: false) == .user)
        #expect(
            AppDelegate.launchProvenance(
                openedUntitledFile: false, openedDocuments: true, hasOpenAppleEvent: false,
                isLoginItemLaunch: false, isDefaultLaunch: false) == .user)
        #expect(
            AppDelegate.launchProvenance(
                openedUntitledFile: false, openedDocuments: false, hasOpenAppleEvent: true,
                isLoginItemLaunch: false, isDefaultLaunch: false) == .user)
        #expect(
            AppDelegate.launchProvenance(
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
                        let provenance = AppDelegate.launchProvenance(
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
            AppDelegate.launchProvenance(
                openedUntitledFile: true, openedDocuments: false, hasOpenAppleEvent: true,
                isLoginItemLaunch: false, isDefaultLaunch: true) == .user)
    }

    @Test("A document launch presents even though it is not a default launch")
    func documentLaunchIsUser() {
        #expect(
            AppDelegate.launchProvenance(
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
        hasLiveGuest: Bool = false
    ) -> AppDelegate.AutomationIdleOutcome {
        AppDelegate.automationIdleOutcome(
            isAutomationLaunch: isAutomationLaunch,
            hasPresentedInterface: hasPresentedInterface,
            hasVisibleUserWindow: hasVisibleUserWindow,
            keepInMenuBar: keepInMenuBar,
            hasUninterruptibleWork: hasUninterruptibleWork,
            hasLiveGuest: hasLiveGuest)
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
}
