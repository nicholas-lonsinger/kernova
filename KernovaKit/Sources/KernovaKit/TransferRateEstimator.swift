import Foundation

/// Smoothed throughput and time-remaining estimate for a monotonically growing
/// byte count (#643).
///
/// A raw Δbytes/Δt reading swings wildly across a chunked vsock transfer — a
/// credit stall reads as 0 B/s, the chunk that follows it as a burst — and a
/// speed/ETA that flickers between "8 seconds" and "3 minutes" is worse than
/// none. This keeps an exponential moving average instead, so the displayed rate
/// tracks real changes (a genuinely slower phase) without chasing per-chunk
/// noise.
///
/// A pure value type with an explicit sample time: the caller passes its own
/// clock, so tests are deterministic and the estimator never reads the wall
/// clock itself.
public struct TransferRateEstimator: Equatable, Sendable {
    /// Weight of the newest instantaneous reading in the moving average.
    ///
    /// Low enough that one stalled or bursty interval can't dominate the
    /// display, high enough that the estimate still converges within a few
    /// seconds of updates at the shared throttle's ~10 Hz ceiling.
    private static let smoothing = 0.25

    /// Shortest interval that yields a usable instantaneous rate.
    ///
    /// Below this, the division amplifies timer granularity into a meaningless
    /// figure. Such a sample is *skipped*, not folded in — the anchor stays put
    /// so the next sample measures across the whole interval rather than losing
    /// those bytes.
    private static let minimumSampleInterval: TimeInterval = 0.05

    /// Byte count and time of the last folded-in sample, or `nil` before the
    /// first `record`.
    private var anchorBytes: UInt64?
    private var anchorSeconds: TimeInterval?

    /// The moving average, or `nil` until two samples a usable interval apart
    /// have landed.
    public private(set) var bytesPerSecond: Double?

    /// Creates an estimator with no samples.
    public init() {}

    /// Folds a cumulative byte count observed at `seconds` (any monotonic
    /// timebase) into the average.
    ///
    /// Ignores a regression in `bytes` — the caller's counts are monotonic, and
    /// treating a reorder as negative throughput would poison the average.
    public mutating func record(bytes: UInt64, seconds: TimeInterval) {
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
    public func secondsRemaining(bytes: UInt64, total: UInt64) -> Double? {
        guard let rate = bytesPerSecond, rate > 0, total > bytes else { return nil }
        return Double(total - bytes) / rate
    }
}
