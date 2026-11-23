import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("VMStatus Tests", .caseScoped)
struct VMStatusTests {

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
        #expect(VMStatus.forceStopping.rawValue == "forceStopping")
        #expect(VMStatus.initialBoot.rawValue == "initialBoot")
        #expect(VMStatus.error.rawValue == "error")
    }
}
