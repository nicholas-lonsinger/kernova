import Testing

@testable import Kernova

/// Unit tests for `AppDelegate.terminationOutcome` — what the termination gate
/// replies to a quit request (#805).
@Suite("AppDelegate termination outcome")
struct AppDelegateTerminationOutcomeTests {
    private func outcome(
        shouldTerminateAgent: Bool = true,
        isSavePassRunning: Bool = false,
        hasSaveInFlight: Bool = false,
        hasInstancesToSave: Bool = false
    ) -> AppDelegate.TerminationOutcome {
        AppDelegate.terminationOutcome(
            shouldTerminateAgent: shouldTerminateAgent,
            isSavePassRunning: isSavePassRunning,
            hasSaveInFlight: hasSaveInFlight,
            hasInstancesToSave: hasInstancesToSave)
    }

    @Test("a soft quit closes the GUI whatever the VMs are doing")
    func softQuitClosesTheGUI() {
        #expect(outcome(shouldTerminateAgent: false) == .closeGUI)
        #expect(outcome(shouldTerminateAgent: false, hasSaveInFlight: true) == .closeGUI)
        #expect(outcome(shouldTerminateAgent: false, hasInstancesToSave: true) == .closeGUI)
    }

    @Test("a system quit during the save pass is deferred, never vetoed")
    func systemQuitDuringSavePassIsNotVetoed() {
        // `.deferToSavePass` replies `.terminateLater`; a `.terminateCancel` would
        // reach loginwindow as Kernova refusing the logout or shut down.
        #expect(outcome(isSavePassRunning: true) == .deferToSavePass)
    }

    @Test("an idle library terminates immediately")
    func idleLibraryTerminatesNow() {
        #expect(outcome() == .terminateNow)
    }

    @Test("live VMs are save-suspended before termination")
    func liveVMsAreSaved() {
        #expect(outcome(hasInstancesToSave: true) == .saveThenTerminate)
    }

    // MARK: - In-flight save

    @Test("a save already in flight defers the reply with nothing else to save")
    func saveInFlightAloneDefersTermination() {
        // The regression: a VM mid-save is neither `.running` nor `.paused`, so the
        // gate used to see an empty save set and terminate through the write,
        // truncating the save file `saveMachineStateTo` writes in place.
        #expect(outcome(hasSaveInFlight: true) == .saveThenTerminate)
    }

    @Test("a save in flight alongside a live VM defers the reply")
    func saveInFlightWithOtherLiveVMs() {
        #expect(outcome(hasSaveInFlight: true, hasInstancesToSave: true) == .saveThenTerminate)
    }

    // MARK: - Re-entrancy

    @Test(
        "a quit arriving during the save pass defers to it",
        arguments: [true, false])
    func quitDuringSavePassDefersToIt(hasInstancesToSave: Bool) {
        // A second pass would hit `operationInProgress` on the VM already saving
        // and force-stop it mid-write.
        #expect(
            outcome(isSavePassRunning: true, hasInstancesToSave: hasInstancesToSave)
                == .deferToSavePass)
    }

    @Test("a soft quit during the save pass defers to it rather than closing the GUI")
    func softQuitDuringSavePassDefersToIt() {
        // Closing the windows would pop the "still running in the menu bar"
        // reminder seconds before the pass's reply exits the process.
        #expect(outcome(shouldTerminateAgent: false, isSavePassRunning: true) == .deferToSavePass)
    }
}

/// Unit tests for `AppDelegate.terminationSaveStep` — what the termination save
/// pass does with one VM it has selected (#807).
@Suite("AppDelegate termination save step")
struct AppDelegateTerminationSaveStepTests {
    private func step(
        hasLiveSession: Bool = true,
        hasActiveOperation: Bool = false
    ) -> AppDelegate.TerminationSaveStep {
        AppDelegate.terminationSaveStep(
            hasLiveSession: hasLiveSession,
            hasActiveOperation: hasActiveOperation)
    }

    @Test("a settled live VM is saved")
    func settledLiveVMIsSaved() {
        #expect(step() == .save)
    }

    @Test("a live VM holding a lifecycle operation is waited out, not skipped")
    func settlingLiveVMIsWaitedOut() {
        // The regression: a pause holds `.running` and a resume holds `.paused`
        // for the whole VZ await, so the pass reached `trySave` on a VM the
        // coordinator had locked, took `operationInProgress`, and exited with the
        // guest live — an unclean power loss instead of a suspend.
        #expect(step(hasActiveOperation: true) == .waitForOperation)
    }

    @Test("a VM with no live session is skipped whatever it is doing")
    func nonLiveVMIsSkipped() {
        // `.installing`, `.starting` and `.restoring` all fail `hasLiveSession`,
        // which is what keeps an install — tens of minutes — from holding a quit.
        #expect(step(hasLiveSession: false) == .skip)
        #expect(step(hasLiveSession: false, hasActiveOperation: true) == .skip)
    }
}
