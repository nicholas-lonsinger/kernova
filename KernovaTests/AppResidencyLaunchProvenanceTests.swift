import Testing

@testable import Kernova

/// Unit tests for `AppResidencyController.launchProvenance` and
/// `AppResidencyController.automationIdleOutcome` — what decides that a launch nobody
/// performed stays headless, and what decides whether the resulting process
/// keeps running.
@Suite("AppResidencyController launch provenance", .admissionGated)
struct AppResidencyLaunchProvenanceTests {
    /// The classifier, defaulted to a launch carrying no sign of a person: no
    /// open Apple Event, no untitled open, no document, not hidden, and
    /// `isDefaultLaunch` false.
    ///
    /// `openEventIsDirect` defaults to `true` — what the classifier reads when
    /// an open event is present and nothing says otherwise.
    private func provenance(
        openedUntitledFile: Bool = false,
        openedDocuments: Bool = false,
        hasOpenAppleEvent: Bool = false,
        openEventIsDirect: Bool = true,
        isHiddenLaunch: Bool = false,
        isLoginItemLaunch: Bool = false,
        isDefaultLaunch: Bool = false
    ) -> AppResidencyController.LaunchProvenance {
        AppResidencyController.launchProvenance(
            openedUntitledFile: openedUntitledFile,
            openedDocuments: openedDocuments,
            hasOpenAppleEvent: hasOpenAppleEvent,
            openEventIsDirect: openEventIsDirect,
            isHiddenLaunch: isHiddenLaunch,
            isLoginItemLaunch: isLoginItemLaunch,
            isDefaultLaunch: isDefaultLaunch)
    }

    // MARK: - launchProvenance

    @Test("A launch with no sign of a person asking is automation")
    func noSignalsIsAutomation() {
        #expect(provenance() == .automation)
    }

    @Test("A login-item launch outranks every other signal")
    func loginItemWins() {
        for untitled in [true, false] {
            for documents in [true, false] {
                for hidden in [true, false] {
                    for isDefault in [true, false] {
                        #expect(
                            provenance(
                                openedUntitledFile: untitled,
                                openedDocuments: documents,
                                hasOpenAppleEvent: true,
                                openEventIsDirect: false,
                                isHiddenLaunch: hidden,
                                isLoginItemLaunch: true,
                                isDefaultLaunch: isDefault) == .loginItem)
                    }
                }
            }
        }
    }

    @Test("Any single sign of a person asking resolves to a user launch")
    func anyInteractiveSignalIsUser() {
        #expect(provenance(openedUntitledFile: true) == .user)
        #expect(provenance(openedDocuments: true) == .user)
        #expect(provenance(hasOpenAppleEvent: true) == .user)
        #expect(provenance(isDefaultLaunch: true) == .user)
    }

    @Test("Exactly two families of signals classify as automation")
    func automationIsTheSoleHeadlessCombination() {
        var headless: Set<String> = []
        for untitled in [true, false] {
            for documents in [true, false] {
                for openEvent in [true, false] {
                    for direct in [true, false] {
                        for hidden in [true, false] {
                            for isDefault in [true, false] {
                                let verdict = provenance(
                                    openedUntitledFile: untitled,
                                    openedDocuments: documents,
                                    hasOpenAppleEvent: openEvent,
                                    openEventIsDirect: direct,
                                    isHiddenLaunch: hidden,
                                    isDefaultLaunch: isDefault)
                                guard verdict == .automation else { continue }
                                headless.insert(
                                    Self.signalDescription(
                                        untitled: untitled, documents: documents, openEvent: openEvent,
                                        direct: direct, hidden: hidden, isDefault: isDefault))
                            }
                        }
                    }
                }
            }
        }
        // The hidden launch whose open event another process sent, whatever else
        // it claims, and the launch carrying no signal at all.
        #expect(
            headless == [
                "untitled=false documents=false openEvent=true direct=false hidden=true default=false",
                "untitled=false documents=false openEvent=true direct=false hidden=true default=true",
                "untitled=true documents=false openEvent=true direct=false hidden=true default=false",
                "untitled=true documents=false openEvent=true direct=false hidden=true default=true",
                "untitled=false documents=false openEvent=false direct=false hidden=false default=false",
                "untitled=false documents=false openEvent=false direct=false hidden=true default=false",
                "untitled=false documents=false openEvent=false direct=true hidden=false default=false",
                "untitled=false documents=false openEvent=false direct=true hidden=true default=false",
            ])
    }

    /// Names one point in the signal space, so the exhaustive sweep can state
    /// the headless set rather than count it.
    private static func signalDescription(
        untitled: Bool, documents: Bool, openEvent: Bool, direct: Bool, hidden: Bool, isDefault: Bool
    ) -> String {
        "untitled=\(untitled) documents=\(documents) openEvent=\(openEvent) "
            + "direct=\(direct) hidden=\(hidden) default=\(isDefault)"
    }

    @Test("A Finder double-click or a Dock click presents")
    func finderOrDockLaunchIsUser() {
        // Measured identically apart from the sender PID, which the classifier
        // does not read: a foreign `kAELocalProcess` open event, an untitled
        // open, a default launch, and not hidden.
        #expect(
            provenance(
                openedUntitledFile: true, hasOpenAppleEvent: true, openEventIsDirect: false,
                isDefaultLaunch: true) == .user)
    }

    @Test("A Shortcuts Open App action or `open -a` presents")
    func directOpenLaunchIsUser() {
        // Both arrive as `kAEDirectCall` with the app itself as sender.
        #expect(
            provenance(openedUntitledFile: true, hasOpenAppleEvent: true, isDefaultLaunch: true) == .user)
    }

    @Test("An ordinary Launch Services open presents, foregrounded or not")
    func launchServicesOpenIsUser() {
        // `open -g -j <app>` comes up hidden, but its open event is the app's
        // own `kAEDirectCall` — a person asked for the app, just not for the
        // front. Presenting is the decided behavior.
        #expect(
            provenance(
                openedUntitledFile: true, hasOpenAppleEvent: true, isHiddenLaunch: true,
                isDefaultLaunch: true) == .user)
    }

    @Test("An App Intents launch with no open event is automation")
    func cleanAppIntentsLaunchIsAutomation() {
        #expect(provenance(isHiddenLaunch: true) == .automation)
    }

    @Test("An App Intents launch the runner also sent an open event is automation")
    func appIntentsLaunchWithRunnerOpenEventIsAutomation() {
        // The runner sends `kAEOpenApplication` on roughly one launch in four,
        // with an untitled open and a default launch behind it — every signal
        // the interactive rule reads. Hidden and foreign outranks all of them.
        #expect(
            provenance(
                openedUntitledFile: true, hasOpenAppleEvent: true, openEventIsDirect: false,
                isHiddenLaunch: true, isDefaultLaunch: true) == .automation)
    }

    @Test("A document launch presents even though it is not a default launch")
    func documentLaunchIsUser() {
        #expect(provenance(openedDocuments: true, hasOpenAppleEvent: true) == .user)
    }

    @Test("A hidden document open presents, outranking the hidden-and-foreign rule")
    func hiddenDocumentLaunchIsUser() {
        #expect(
            provenance(
                openedDocuments: true, hasOpenAppleEvent: true, openEventIsDirect: false,
                isHiddenLaunch: true) == .user)
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
