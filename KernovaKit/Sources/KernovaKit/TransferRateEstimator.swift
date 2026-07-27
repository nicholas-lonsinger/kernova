import Foundation

/// Smoothed throughput and time-remaining estimate for a monotonically growing
/// byte count.
///
/// A raw Δbytes/Δt reading swings wildly across a chunked vsock transfer (a
/// credit stall reads as 0 B/s, the chunk after it as a burst), so this keeps an
/// exponential moving average instead. The caller passes its own sample time;
/// the estimator never reads the wall clock itself.
struct TransferRateEstimator: Equatable, Sendable {
    /// Weight of the newest instantaneous reading in the moving average.
    private static let smoothing = 0.25

    /// Shortest interval that yields a usable instantaneous rate.
    ///
    /// A shorter sample is *skipped*, not folded in — the anchor stays put so the
    /// next sample measures the whole interval rather than losing those bytes.
    private static let minimumSampleInterval: TimeInterval = 0.05

    /// Byte count and time of the last folded-in sample, or `nil` before the
    /// first `record`.
    private var anchorBytes: UInt64?
    private var anchorSeconds: TimeInterval?

    /// The moving average, or `nil` until two samples a usable interval apart
    /// have landed.
    private(set) var bytesPerSecond: Double?

    /// Creates an estimator with no samples.
    init() {}

    /// Folds a cumulative byte count observed at `seconds` (any monotonic
    /// timebase) into the average.
    ///
    /// A regression in `bytes` is ignored rather than folded in as negative
    /// throughput.
    mutating func record(bytes: UInt64, seconds: TimeInterval) {
        guard let previousBytes = anchorBytes, let previousSeconds = anchorSeconds else {
            anchorBytes = bytes
            anchorSeconds = seconds
            return
        }
        let elapsed = seconds - previousSeconds
        guard elapsed >= Self.minimumSampleInterval, bytes > previousBytes else { return }
        let instantaneous = Double(bytes - previousBytes) / elapsed
        anchorBytes = bytes
        anchorSeconds = seconds
        guard let current = bytesPerSecond else {
            bytesPerSecond = instantaneous
            return
        }
        bytesPerSecond = current * (1 - Self.smoothing) + instantaneous * Self.smoothing
    }

    /// Seconds until `total` is reached at the current rate, or `nil` when there
    /// is no rate yet, nothing left to transfer, or the total is unknown.
    func secondsRemaining(bytes: UInt64, total: UInt64) -> Double? {
        guard let rate = bytesPerSecond, rate > 0, total > bytes else { return nil }
        return Double(total - bytes) / rate
    }
}
