import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Unit tests for `AppTerminationController.terminationOutcome` — what the termination gate
/// replies to a quit request (#805).
@Suite("AppTerminationController outcome", .caseScoped)
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
