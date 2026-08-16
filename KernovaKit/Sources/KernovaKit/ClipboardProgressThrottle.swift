import Foundation

/// Pure throttle for a pull's per-chunk progress consumers: decides whether to
/// forward a `(bytesTransferred, totalBytes)` update now.
///
/// A multi-GB pull fires the receiver's per-chunk callback tens of thousands of
/// times; forwarding every one would flood a consumer's main-queue republishes.
/// The final chunk (`bytes >= total`) always forwards, so a determinate readout
/// reaches 100% rather than stalling one throttle interval short. Stateless — the
/// caller owns the watermarks.
enum FetchProgressThrottle {
    /// Minimum fraction of the total that must accumulate since the last push.
    static let minByteFraction = 0.01
    /// Minimum wall-clock gap between time-triggered pushes.
    static let minInterval: TimeInterval = 0.1

    /// Whether `bytes`/`total` warrants a push given the last pushed byte count and
    /// the time since the last push.
    ///
    /// Seed `elapsedSinceLastPush` with a large value for the first push, so the
    /// bar leaves zero promptly.
    static func shouldPush(
        bytes: UInt64, total: UInt64, lastPushedBytes: UInt64, elapsedSinceLastPush: TimeInterval
    ) -> Bool {
        guard bytes > lastPushedBytes else { return false }
        if total > 0, bytes >= total { return true }
        if elapsedSinceLastPush >= minInterval { return true }
        guard total > 0 else { return false }
        return Double(bytes - lastPushedBytes) >= Double(total) * minByteFraction
    }
}

/// The stateful half of the throttle: owns one consumer's watermarks and
/// answers "forward this update?" under its own lock.
///
/// `ClipboardTransferOperation` holds one per *operation* — the aggregate is a
/// single byte stream even when several transfers feed it — so every progress
/// surface republishes at one shared policy.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`.
final class FetchProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastForwardedBytes: UInt64 = 0
    /// When the last update was forwarded; `nil` until the first, so the first
    /// forward chunk always passes (elapsed reads as effectively infinite).
    private var lastForwardAt: DispatchTime?

    /// Creates a coalescer with empty watermarks, so its first forward-progress
    /// update always passes.
    init() {}

    /// Records that an update was forwarded without asking `shouldForward` —
    /// a consumer that bypasses the throttle for something the user must see
    /// (a reveal, a terminal, an item finishing).
    ///
    /// Without it the watermarks would still describe the last *throttled*
    /// forward, so the next update would measure its delta from a byte count
    /// already on screen and sail through the policy however small it was.
    func markForwarded(bytesTransferred: UInt64) {
        lock.withLock {
            lastForwardedBytes = max(lastForwardedBytes, bytesTransferred)
            lastForwardAt = DispatchTime.now()
        }
    }

    /// Whether `(bytesTransferred, totalBytes)` should be forwarded now,
    /// advancing the watermarks when it should.
    func shouldForward(bytesTransferred: UInt64, totalBytes: UInt64) -> Bool {
        let now = DispatchTime.now()
        return lock.withLock {
            let elapsed =
                lastForwardAt.map {
                    Double(now.uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000
                } ?? .greatestFiniteMagnitude
            guard
                FetchProgressThrottle.shouldPush(
                    bytes: bytesTransferred, total: totalBytes,
                    lastPushedBytes: lastForwardedBytes, elapsedSinceLastPush: elapsed)
            else { return false }
            lastForwardedBytes = bytesTransferred
            lastForwardAt = now
            return true
        }
    }
}
