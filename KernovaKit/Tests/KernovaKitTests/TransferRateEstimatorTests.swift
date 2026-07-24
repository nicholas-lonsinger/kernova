import Foundation
import Testing

@testable import KernovaKit

/// Unit tests for `TransferRateEstimator` — the smoothed throughput and ETA
/// behind the paste progress readout (#643).
///
/// The estimator takes its sample times as arguments, so every case here is a
/// pure calculation with no clock and no wait.
@Suite("TransferRateEstimator")
struct TransferRateEstimatorTests {
    @Test("one sample is not enough for a rate")
    func firstSampleEstablishesOnlyAnAnchor() {
        var estimator = TransferRateEstimator()
        estimator.record(bytes: 1_000, seconds: 0)
        #expect(estimator.bytesPerSecond == nil)
    }

    @Test("the second usable sample yields its instantaneous rate")
    func secondSampleYieldsRate() {
        var estimator = TransferRateEstimator()
        estimator.record(bytes: 0, seconds: 0)
        estimator.record(bytes: 1_000, seconds: 1)
        #expect(estimator.bytesPerSecond == 1_000)
    }

    @Test("a steady stream converges on its true rate")
    func steadyStreamConverges() throws {
        var estimator = TransferRateEstimator()
        for step in 0...20 {
            estimator.record(bytes: UInt64(step * 500), seconds: Double(step) * 0.5)
        }
        let rate = try #require(estimator.bytesPerSecond)
        #expect(abs(rate - 1_000) < 1)
    }

    @Test("a single burst moves the average without taking it over")
    func burstIsSmoothed() throws {
        var estimator = TransferRateEstimator()
        for step in 0...10 {
            estimator.record(bytes: UInt64(step * 100), seconds: Double(step))
        }
        // Steady at 100 B/s, then one interval ten times as fast.
        estimator.record(bytes: 2_000, seconds: 11)
        let rate = try #require(estimator.bytesPerSecond)
        #expect(rate > 100)
        #expect(rate < 1_000)
    }

    @Test("samples closer together than the minimum interval are skipped, not folded in")
    func subIntervalSamplesSkipped() {
        var estimator = TransferRateEstimator()
        estimator.record(bytes: 0, seconds: 0)
        estimator.record(bytes: 10, seconds: 0.01)
        #expect(estimator.bytesPerSecond == nil)

        // Skipping left the anchor at (0, 0), so this measures the whole second
        // rather than losing the bytes in between.
        estimator.record(bytes: 1_000, seconds: 1)
        #expect(estimator.bytesPerSecond == 1_000)
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
