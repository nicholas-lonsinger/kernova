import KernovaAgentCore
import KernovaTestSupport
import Testing

@testable import KernovaTransferProgress

@Suite("ClipboardTransferFailure(pullEndedWith:)", .caseScoped)
struct ClipboardPullFailureTests {
    @Test("a pull reset TOO_LARGE reports too large, at the limit the reset carried")
    func tooLargeKeepsItsLimit() {
        let error = WireError(.tooLarge, limit: 2_000_000_000)
        #expect(ClipboardTransferFailure(pullEndedWith: error, fileCount: nil) == .tooLarge(limitBytes: 2_000_000_000))
    }
}
