import KernovaTestSupport
import Testing

@testable import KernovaTestSupport

@Suite("TestScratchDirectory after its case ended", .caseScoped)
struct TestScratchDirectoryEndedCaseTests {
    @Test("a mint into a case's ledger after the case ended stops the process")
    func mintAfterTheCaseEndedStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            let ended = await TestScratchLedger.scoping { TestScratchLedger.current }
            TestScratchLedger.$current.withValue(ended) {
                _ = TestScratchDirectory(prefix: "ScratchLedgerEnded")
            }
        }
    }

    @Test("a forCase into a case's ledger after the case ended stops the process")
    func forCaseAfterTheCaseEndedStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            let ended = await TestScratchLedger.scoping { TestScratchLedger.current }
            TestScratchLedger.$current.withValue(ended) {
                _ = TestScratchDirectory.forCase(prefix: "ScratchLedgerEnded")
            }
        }
    }
}
