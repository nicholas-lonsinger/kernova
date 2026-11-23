import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardPasteLimit", .caseScoped)
struct ClipboardPasteLimitTests {

    // MARK: - fromPolicy

    @Test("a policy value past Int's range clamps instead of trapping")
    func fromPolicyClampsAnOversizedValue() {
        #expect(ClipboardPasteLimit.fromPolicy(UInt64.max) == Int.max)
    }
}
