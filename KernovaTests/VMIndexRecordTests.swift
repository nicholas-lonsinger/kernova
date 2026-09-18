import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The `UserDefaults` half of the Spotlight index record: what a later launch
/// reads back.
@Suite("VM Index Record Tests")
@MainActor
struct VMIndexRecordTests {
    @Test("Identifiers written to the record read back as written")
    func identifiersRoundTripThroughDefaults() {
        let record = DefaultsVMIndexRecord(defaults: makeTestDefaults())
        let written: Set<UUID> = [UUID(), UUID(), UUID()]

        record.indexedVMIDs = written

        #expect(record.indexedVMIDs == written)
    }
}
