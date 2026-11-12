import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Unit tests for `TransferRateEstimator` — the smoothed throughput and ETA
/// behind the paste progress readout (#643).
///
/// The estimator takes its sample times as arguments, so every case here is a
/// pure calculation with no clock and no wait.
@Suite("TransferRateEstimator", .caseScoped)
struct TransferRateEstimatorTests {
    @Test("a steady stream converges on its true rate")
    func steadyStreamConverges() throws {
        var estimator = TransferRateEstimator()
        for step in 0...20 {
            estimator.record(bytes: UInt64(step * 500), seconds: Double(step) * 0.5)
        }
        let rate = try #require(estimator.bytesPerSecond)
        #expect(abs(rate - 1_000) < 1)
    }

    @Test("a byte count that fails to advance never poisons the average")
    func stalledSampleIgnored() {
        var estimator = TransferRateEstimator()
        estimator.record(bytes: 0, seconds: 0)
        estimator.record(bytes: 1_000, seconds: 1)
        estimator.record(bytes: 1_000, seconds: 2)
        #expect(estimator.bytesPerSecond == 1_000)
    }

    @Test("time remaining divides what is left by the current rate")
    func timeRemainingFromRate() {
        var estimator = TransferRateEstimator()
        estimator.record(bytes: 0, seconds: 0)
        estimator.record(bytes: 1_000, seconds: 1)
        #expect(estimator.secondsRemaining(bytes: 1_000, total: 5_000) == 4)
    }

    @Test("time remaining is unknown without a rate, and absent once complete")
    func timeRemainingUnknownCases() {
        var estimator = TransferRateEstimator()
        #expect(estimator.secondsRemaining(bytes: 0, total: 1_000) == nil)

        estimator.record(bytes: 0, seconds: 0)
        estimator.record(bytes: 1_000, seconds: 1)
        #expect(estimator.secondsRemaining(bytes: 1_000, total: 1_000) == nil)
        #expect(estimator.secondsRemaining(bytes: 0, total: 0) == nil)
    }
}
