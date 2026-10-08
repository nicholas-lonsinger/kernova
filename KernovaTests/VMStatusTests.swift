import KernovaKit
import Testing

@testable import Kernova

@Suite("VMStatus Tests", .caseScoped)
struct VMStatusTests {
    // MARK: - Display Name

    @Test("displayName returns expected string for each status")
    func displayName() {
        #expect(VMStatus.stopped.displayName == "Stopped")
        #expect(VMStatus.starting.displayName == "Starting")
        #expect(VMStatus.running.displayName == "Running")
        #expect(VMStatus.paused.displayName == "Paused")
        #expect(VMStatus.suspended.displayName == "Suspended")
        #expect(VMStatus.saving.displayName == "Suspending")
        #expect(VMStatus.restoring.displayName == "Restoring")
        #expect(VMStatus.installing.displayName == "Installing")
        #expect(VMStatus.initialBoot.displayName == "Initial Boot")
        #expect(VMStatus.error.displayName == "Error")
        #expect(VMStatus.snapshotting.displayName == "Taking Snapshot")
    }

    @Test("phrase reads each status mid-sentence, the held VM included")
    func phrase() {
        let rows: [(VMStatus, String)] = [
            (.stopped, "stopped"),
            (.starting, "starting"),
            (.running, "running"),
            (.paused, "paused"),
            (.suspended, "suspended"),
            (.saving, "suspending"),
            (.snapshotting, "taking a snapshot"),
            (.restoring, "restoring"),
            (.installing, "installing"),
            (.initialBoot, "not yet booted"),
            (.error, "in an error state"),
        ]
        for (status, phrase) in rows {
            #expect(status.phrase(heldByAnotherCopy: false) == phrase)
            #expect(VMStatus.phrase(forWireName: status.rawValue, heldByAnotherCopy: false) == phrase)
            #expect(status.phrase(heldByAnotherCopy: true) == "in use by another copy of Kernova")
        }
        #expect(VMStatus.phrase(forWireName: VMStatus.preparingWireName, heldByAnotherCopy: false) == "preparing")
        #expect(
            VMStatus.phrase(forWireName: "teleporting", heldByAnotherCopy: true)
                == "in use by another copy of Kernova")
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
        #expect(VMStatus.suspended.transitionLabel == nil)
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
        #expect(VMStatus.suspended.rawValue == "suspended")
        #expect(VMStatus.saving.rawValue == "saving")
        #expect(VMStatus.snapshotting.rawValue == "snapshotting")
        #expect(VMStatus.restoring.rawValue == "restoring")
        #expect(VMStatus.installing.rawValue == "installing")
        #expect(VMStatus.initialBoot.rawValue == "initialBoot")
        #expect(VMStatus.error.rawValue == "error")
    }

    @Test("A wire status reads back in words, preparing included")
    func wireNamesReadBackInWords() {
        #expect(VMStatus.displayName(forWireName: "running", heldByAnotherCopy: false) == "Running")
        #expect(VMStatus.displayName(forWireName: "suspended", heldByAnotherCopy: false) == "Suspended")
        #expect(VMStatus.displayName(forWireName: "initialBoot", heldByAnotherCopy: false) == "Initial Boot")
        // Not a VMStatus case, and the one wire name that still has words.
        #expect(VMStatus(rawValue: VMStatus.preparingWireName) == nil)
        #expect(
            VMStatus.displayName(forWireName: VMStatus.preparingWireName, heldByAnotherCopy: false)
                == "Preparing")
        // A name from no vocabulary this build knows falls back to itself.
        #expect(VMStatus.displayName(forWireName: "teleporting", heldByAnotherCopy: false) == "teleporting")
    }

    @Test("A VM another copy holds reads as held, whatever status this copy sees")
    func heldByAnotherCopyWinsOverStatus() {
        #expect(VMStatus.stopped.displayName(heldByAnotherCopy: true) == VMStatus.heldByAnotherCopyDisplayName)
        #expect(VMStatus.suspended.displayName(heldByAnotherCopy: false) == "Suspended")
        #expect(
            VMStatus.displayName(forWireName: "stopped", heldByAnotherCopy: true)
                == VMStatus.heldByAnotherCopyDisplayName)
        #expect(
            VMStatus.displayName(forWireName: "teleporting", heldByAnotherCopy: true)
                == VMStatus.heldByAnotherCopyDisplayName)
    }
}
