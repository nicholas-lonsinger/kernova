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
    @Test("maxConnectAttempts is 15 for the production 30s wait / 2s retry delay")
    func productionValuesMatchToday() {
        #expect(FileProviderServicingTiming.connectWait == 30)
        #expect(FileProviderServicingTiming.connectRetryDelaySeconds == 2)
        #expect(FileProviderServicingTiming.maxConnectAttempts == 15)
    }

    @Test("connectRetryDelay derives from connectRetryDelaySeconds")
    func retryDelayDerivesFromSeconds() {
        #expect(
            FileProviderServicingTiming.connectRetryDelay
                == .milliseconds(Int(FileProviderServicingTiming.connectRetryDelaySeconds * 1000)))
    }

    @Test("the retry budget always spans the connect wait — the invariant #466 makes structural")
    func retryBudgetSpansConnectWait() {
        let spanned =
            Double(FileProviderServicingTiming.maxConnectAttempts)
            * FileProviderServicingTiming.connectRetryDelaySeconds
        #expect(spanned >= FileProviderServicingTiming.connectWait)
    }
}
