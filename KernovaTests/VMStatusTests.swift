import Testing
import SwiftUI
@testable import Kernova

@Suite("VMStatus Tests")
struct VMStatusTests {

    // MARK: - State Checks

    @Test("canStart returns true for stopped and error states")
    func canStart() {
        #expect(VMStatus.stopped.canStart == true)
        #expect(VMStatus.error.canStart == true)
        #expect(VMStatus.running.canStart == false)
        #expect(VMStatus.paused.canStart == false)
        #expect(VMStatus.starting.canStart == false)
        #expect(VMStatus.saving.canStart == false)
        #expect(VMStatus.restoring.canStart == false)
        #expect(VMStatus.installing.canStart == false)
    }

    @Test("canStop returns true for running and paused states")
    func canStop() {
        #expect(VMStatus.running.canStop == true)
        #expect(VMStatus.paused.canStop == true)
        #expect(VMStatus.stopped.canStop == false)
        #expect(VMStatus.starting.canStop == false)
        #expect(VMStatus.saving.canStop == false)
        #expect(VMStatus.restoring.canStop == false)
        #expect(VMStatus.installing.canStop == false)
        #expect(VMStatus.error.canStop == false)
    }

    @Test("canPause returns true only for running state")
    func canPause() {
        #expect(VMStatus.running.canPause == true)
        #expect(VMStatus.stopped.canPause == false)
        #expect(VMStatus.paused.canPause == false)
        #expect(VMStatus.starting.canPause == false)
        #expect(VMStatus.saving.canPause == false)
        #expect(VMStatus.restoring.canPause == false)
        #expect(VMStatus.installing.canPause == false)
        #expect(VMStatus.error.canPause == false)
    }

    @Test("canResume returns true only for paused state")
    func canResume() {
        #expect(VMStatus.paused.canResume == true)
        #expect(VMStatus.stopped.canResume == false)
        #expect(VMStatus.running.canResume == false)
        #expect(VMStatus.starting.canResume == false)
        #expect(VMStatus.saving.canResume == false)
        #expect(VMStatus.restoring.canResume == false)
        #expect(VMStatus.installing.canResume == false)
        #expect(VMStatus.error.canResume == false)
    }

    @Test("canSave returns true for running and paused states")
    func canSave() {
        #expect(VMStatus.running.canSave == true)
        #expect(VMStatus.paused.canSave == true)
        #expect(VMStatus.stopped.canSave == false)
        #expect(VMStatus.starting.canSave == false)
        #expect(VMStatus.saving.canSave == false)
        #expect(VMStatus.restoring.canSave == false)
        #expect(VMStatus.installing.canSave == false)
        #expect(VMStatus.error.canSave == false)
    }

    @Test("canEditSettings returns true for stopped and error states")
    func canEditSettings() {
        #expect(VMStatus.stopped.canEditSettings == true)
        #expect(VMStatus.error.canEditSettings == true)
        #expect(VMStatus.running.canEditSettings == false)
        #expect(VMStatus.paused.canEditSettings == false)
        #expect(VMStatus.starting.canEditSettings == false)
        #expect(VMStatus.saving.canEditSettings == false)
        #expect(VMStatus.restoring.canEditSettings == false)
        #expect(VMStatus.installing.canEditSettings == false)
    }

    // MARK: - Transitioning

    @Test("isTransitioning returns true for starting, saving, restoring, and installing")
    func isTransitioning() {
        #expect(VMStatus.starting.isTransitioning == true)
        #expect(VMStatus.saving.isTransitioning == true)
        #expect(VMStatus.restoring.isTransitioning == true)
        #expect(VMStatus.installing.isTransitioning == true)
        #expect(VMStatus.stopped.isTransitioning == false)
        #expect(VMStatus.running.isTransitioning == false)
        #expect(VMStatus.paused.isTransitioning == false)
        #expect(VMStatus.error.isTransitioning == false)
    }

    // MARK: - Display Name

    @Test("displayName returns expected string for each status")
    func displayName() {
        #expect(VMStatus.stopped.displayName == "Stopped")
        #expect(VMStatus.starting.displayName == "Starting")
        #expect(VMStatus.running.displayName == "Running")
        #expect(VMStatus.paused.displayName == "Paused")
        #expect(VMStatus.saving.displayName == "Saving")
        #expect(VMStatus.restoring.displayName == "Restoring")
        #expect(VMStatus.installing.displayName == "Installing")
        #expect(VMStatus.error.displayName == "Error")
    }

    // MARK: - Status Color

    @Test("statusColor maps each status to the expected color")
    func statusColor() {
        #expect(VMStatus.stopped.statusColor == .secondary)
        #expect(VMStatus.starting.statusColor == .orange)
        #expect(VMStatus.running.statusColor == .green)
        #expect(VMStatus.paused.statusColor == .yellow)
        #expect(VMStatus.saving.statusColor == .orange)
        #expect(VMStatus.restoring.statusColor == .orange)
        #expect(VMStatus.installing.statusColor == .orange)
        #expect(VMStatus.error.statusColor == .red)
    }
}
