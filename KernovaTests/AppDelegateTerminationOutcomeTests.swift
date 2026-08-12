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
