import KernovaKit
import Testing

@testable import Kernova

@Suite("VMStatus Tests", .admissionGated)
struct VMStatusTests {
    // MARK: - Display Name

    @Test("displayName returns expected string for each status")
    func displayName() {
        #expect(VMStatus.stopped.displayName == "Stopped")
        #expect(VMStatus.starting.displayName == "Starting")
        #expect(VMStatus.running.displayName == "Running")
        #expect(VMStatus.paused.displayName == "Paused")
        #expect(VMStatus.saving.displayName == "Suspending")
        #expect(VMStatus.restoring.displayName == "Restoring")
        #expect(VMStatus.installing.displayName == "Installing")
        #expect(VMStatus.initialBoot.displayName == "Initial Boot")
        #expect(VMStatus.error.displayName == "Error")
        #expect(VMStatus.snapshotting.displayName == "Taking Snapshot")
    }

    // MARK: - Transition Label

    @Test("transitionLabel returns a label for the write-in-place transitions only")
    func transitionLabel() {
        #expect(VMStatus.saving.transitionLabel == "Suspending\u{2026}")
        #expect(VMStatus.restoring.transitionLabel == "Restoring\u{2026}")
        #expect(VMStatus.snapshotting.transitionLabel == "Taking Snapshot\u{2026}")
        #expect(VMStatus.stopped.transitionLabel == nil)
        #expect(VMStatus.starting.transitionLabel == nil)
        #expect(VMStatus.running.transitionLabel == nil)
        #expect(VMStatus.paused.transitionLabel == nil)
        #expect(VMStatus.installing.transitionLabel == nil)
        #expect(VMStatus.initialBoot.transitionLabel == nil)
        #expect(VMStatus.error.transitionLabel == nil)
    }

    // MARK: - Wire Vocabulary

    @Test("The raw value every automation surface reads is the case name")
    func rawValuesAreTheWireVocabulary() {
        #expect(VMStatus.stopped.rawValue == "stopped")
        #expect(VMStatus.starting.rawValue == "starting")
        #expect(VMStatus.running.rawValue == "running")
        #expect(VMStatus.paused.rawValue == "paused")
        #expect(VMStatus.saving.rawValue == "saving")
        #expect(VMStatus.snapshotting.rawValue == "snapshotting")
        #expect(VMStatus.restoring.rawValue == "restoring")
        #expect(VMStatus.installing.rawValue == "installing")
        #expect(VMStatus.initialBoot.rawValue == "initialBoot")
        #expect(VMStatus.error.rawValue == "error")
    }

    @Test("A wire status reads back in words, preparing included")
    func wireNamesReadBackInWords() {
        #expect(VMStatus.displayName(forWireName: "running") == "Running")
        #expect(VMStatus.displayName(forWireName: "initialBoot") == "Initial Boot")
        // Not a VMStatus case, and the one wire name that still has words.
        #expect(VMStatus(rawValue: VMStatus.preparingWireName) == nil)
        #expect(VMStatus.displayName(forWireName: VMStatus.preparingWireName) == "Preparing")
        // A name from no vocabulary this build knows falls back to itself.
        #expect(VMStatus.displayName(forWireName: "teleporting") == "teleporting")
    }
}
