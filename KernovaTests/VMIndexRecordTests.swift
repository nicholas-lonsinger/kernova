import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The record of what the Spotlight index holds: what a later launch reads
/// back out of `UserDefaults`.
@Suite("VM Index Record Tests")
@MainActor
struct VMIndexRecordTests {
    @Test("Identifiers written to the record read back as written")
    func identifiersRoundTripThroughDefaults() {
        let record = VMIndexRecord(defaults: makeTestDefaults())
        let written: Set<UUID> = [UUID(), UUID(), UUID()]

        record.indexedVMIDs = written

        #expect(record.indexedVMIDs == written)
    }
}
