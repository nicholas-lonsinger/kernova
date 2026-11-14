import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardPasteLimit", .caseScoped)
struct ClipboardPasteLimitTests {
    // MARK: - resolve

    @Test("no stored preference resolves to the default")
    func resolveNilIsTheDefault() {
        #expect(ClipboardPasteLimit.resolve(nil) == ClipboardPasteLimit.defaultBytes)
    }

    @Test("a value between stops resolves to the nearer one")
    func resolveSnapsBetweenStops() {
        // Just above 1 GiB is nearer 1 GiB than 2 GiB.
        let oneGiB = 1024 * 1024 * 1024
        #expect(ClipboardPasteLimit.resolve(oneGiB + 1) == oneGiB)
        // Just below 2 GiB is nearer 2 GiB.
        #expect(
            ClipboardPasteLimit.resolve(ClipboardPasteLimit.defaultBytes - 1)
                == ClipboardPasteLimit.defaultBytes)
    }

    // MARK: - fromPolicy

    @Test("an unset policy field leaves the receiver on its own default")
    func fromPolicyTreatsZeroAsUnset() {
        // Reading `0` literally would be a ceiling of zero bytes — every paste
        // refused — rather than "the host said nothing".
        #expect(ClipboardPasteLimit.fromPolicy(0) == ClipboardPasteLimit.defaultBytes)
    }

    @Test("a policy value past Int's range clamps instead of trapping")
    func fromPolicyClampsAnOversizedValue() {
        #expect(ClipboardPasteLimit.fromPolicy(UInt64.max) == Int.max)
    }

    // MARK: - displayLimit

    @Test("the display string renders the ceiling it is given")
    func displayLimitRendersTheCeiling() throws {
        #expect(ClipboardPasteLimit.displayLimit(ClipboardPasteLimit.defaultBytes) == "2 GB")
        #expect(ClipboardPasteLimit.displayLimit(512 * 1024 * 1024) == "512 MB")
        #expect(ClipboardPasteLimit.displayLimit(16 * 1024 * 1024 * 1024) == "16 GB")
        // Halves keep one decimal place rather than rounding away.
        #expect(ClipboardPasteLimit.displayLimit(1536 * 1024 * 1024) == "1.5 GB")
    }

    // MARK: - estimatedStreamSeconds

    @Test("the estimate is the ceiling over the measured throughput")
    func estimateDividesByThroughput() {
        let throughput = ClipboardPasteLimit.measuredThroughputBytesPerSecond
        #expect(ClipboardPasteLimit.estimatedStreamSeconds(throughput * 10) == 10)
        // 2 GiB at 366 MiB/s.
        #expect(ClipboardPasteLimit.estimatedStreamSeconds(ClipboardPasteLimit.defaultBytes) == 6)
    }

    @Test("a sub-second payload still reads as one second, never zero")
    func estimateFloorsAtOneSecond() {
        #expect(ClipboardPasteLimit.estimatedStreamSeconds(1) == 1)
        #expect(ClipboardPasteLimit.estimatedStreamSeconds(0) == 1)
    }
}
