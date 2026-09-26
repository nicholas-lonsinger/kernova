import KernovaTestSupport
import Testing

@testable import Kernova

/// Unit tests for `AppTerminationController.terminationOutcome` — what the termination gate
/// replies to a quit request (#805).
@Suite("AppTerminationController outcome", .admissionGated)
struct AppTerminationOutcomeTests {
    private func outcome(
        hasCompletedSavePass: Bool = false,
        shouldTerminateAgent: Bool = true,
        isSavePassRunning: Bool = false,
        quitMustWaitOut: Bool = false,
        hasInstancesToSave: Bool = false
    ) -> AppTerminationController.TerminationOutcome {
        AppTerminationController.terminationOutcome(
            hasCompletedSavePass: hasCompletedSavePass,
            shouldTerminateAgent: shouldTerminateAgent,
            isSavePassRunning: isSavePassRunning,
            quitMustWaitOut: quitMustWaitOut,
            hasInstancesToSave: hasInstancesToSave)
    }

    @Test("a soft quit closes the GUI whatever the VMs are doing")
    func softQuitClosesTheGUI() {
        #expect(outcome(shouldTerminateAgent: false) == .closeGUI)
        #expect(outcome(shouldTerminateAgent: false, quitMustWaitOut: true) == .closeGUI)
        #expect(outcome(shouldTerminateAgent: false, hasInstancesToSave: true) == .closeGUI)
    }

    @Test("a system quit during the save pass is deferred, never vetoed")
    func systemQuitDuringSavePassIsNotVetoed() {
        // `.deferToSavePass` replies `.terminateLater`; a `.terminateCancel` would
        // reach loginwindow as Kernova refusing the logout or shut down.
        #expect(outcome(isSavePassRunning: true) == .deferToSavePass)
    }

    @Test("the app's own two-phase quit is answered at once, whatever is still live")
    func completedSavePassTerminatesNow() {
        // `requestFullQuit` saves first and asks second, so by the time the gate
        // is consulted there is nothing left to wait for — and answering
        // `.terminateLater` here would enter the nested wait the two-phase quit
        // exists to avoid.
        #expect(outcome(hasCompletedSavePass: true) == .terminateNow)
        #expect(
            outcome(hasCompletedSavePass: true, isSavePassRunning: true, hasInstancesToSave: true)
                == .terminateNow)
        // Even the soft-quit downgrade: the process is already leaving.
        #expect(
            outcome(hasCompletedSavePass: true, shouldTerminateAgent: false) == .terminateNow)
        #expect(outcome(hasCompletedSavePass: true, quitMustWaitOut: true) == .terminateNow)
    }

    @Test("an idle library terminates immediately")
    func idleLibraryTerminatesNow() {
        #expect(outcome() == .terminateNow)
    }

    @Test("live VMs are save-suspended before termination")
    func liveVMsAreSaved() {
        #expect(outcome(hasInstancesToSave: true) == .saveThenTerminate)
    }

    // MARK: - Work a quit waits out

    @Test("work a quit must wait out defers the reply with nothing else to save")
    func waitOutAloneDefersTermination() {
        // A VM mid-save or mid-revert has no live session to save, so without
        // this the gate would reply `.terminateNow` and exit through the write.
        #expect(outcome(quitMustWaitOut: true) == .saveThenTerminate)
    }

    @Test("work a quit must wait out alongside a live VM defers the reply")
    func waitOutWithOtherLiveVMs() {
        #expect(outcome(quitMustWaitOut: true, hasInstancesToSave: true) == .saveThenTerminate)
    }

    // MARK: - Re-entrancy

    @Test(
        "a quit arriving during the save pass defers to it",
        arguments: [true, false])
    func quitDuringSavePassDefersToIt(hasInstancesToSave: Bool) {
        // A second pass would be refused as busy on the VM already saving, and
        // force-stop it mid-write.
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
