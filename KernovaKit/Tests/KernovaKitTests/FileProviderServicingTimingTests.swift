import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `FileProviderServicingTiming` (#466) — the structural
/// coupling between the extension's connect wait and the owner's reconnect
/// retry budget.
///
/// Before this type, the ~30s match between the two sides was two independent
/// literals kept in sync only by a comment; these tests lock the invariant that
/// makes that impossible now — `maxConnectAttempts` is *derived* from
/// `connectWait`/`connectRetryDelaySeconds`, so editing either constant
/// re-derives the other side's budget instead of silently drifting.
@Suite("FileProviderServicingTiming")
struct FileProviderServicingTimingTests {
    @Test("maxConnectAttempts is 16 for the production 30s wait / 2s retry delay")
    func productionValuesMatchToday() {
        #expect(FileProviderServicingTiming.connectWait == 30)
        #expect(FileProviderServicingTiming.connectRetryDelaySeconds == 2)
        #expect(FileProviderServicingTiming.maxConnectAttempts == 16)
    }

    @Test("connectRetryDelay is 2 seconds for the production 2s connectRetryDelaySeconds")
    func retryDelayDerivesFromSeconds() {
        // Asserts a concrete, independently-known value (not the production
        // formula restated) — otherwise a bug in the formula itself (e.g. a
        // wrong unit conversion) would still pass this test.
        #expect(FileProviderServicingTiming.connectRetryDelaySeconds == 2)
        #expect(FileProviderServicingTiming.connectRetryDelay == .seconds(2))
    }

    @Test("the retry budget's actual cumulative delay spans the connect wait")
    func retryBudgetSpansConnectWait() {
        // The owner's *first* connect attempt fires immediately (no preceding
        // delay); only the `maxConnectAttempts - 1` retries after a failure
        // wait `connectRetryDelaySeconds` each — so the real elapsed time
        // across every attempt is `(maxConnectAttempts - 1) *
        // connectRetryDelaySeconds`, not `maxConnectAttempts *
        // connectRetryDelaySeconds`. This is the invariant #466 actually needs
        // to hold (a review found the naive attempts × delay formula
        // undershoots by one delay).
        let actualRetrySpan =
            Double(FileProviderServicingTiming.maxConnectAttempts - 1)
            * FileProviderServicingTiming.connectRetryDelaySeconds
        #expect(actualRetrySpan >= FileProviderServicingTiming.connectWait)
    }
}
