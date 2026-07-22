import Foundation

// Progress reporting for an in-flight File Provider relay pull, for both
// directions (the host app's guest→host "Copy to Mac" and the guest agent's
// host→guest paste run the same owner-side code).
//
// Split out of `FileProviderDomainHost.swift`. Two consumers are fed from the
// pull's single per-chunk `onProgress` callback, and both coalesce that
// ~2,600-per-second raw chunk rate through the pure `FetchProgressThrottle`
// decision:
//  1. `FetchProgressPusher` — pushes byte counts back to the sandboxed
//     extension over the servicing XPC connection, which drives the
//     `fetchContents` `Progress` and so the File Provider item's download badge
//     (#426).
//  2. `PublishedFetchProgress` — publishes a cross-process `NSProgress` keyed
//     to the placeholder's user-visible file URL, which is what Finder's copy
//     dialog actually subscribes to (#634).

// MARK: - Servicing progress push

/// Pure throttle for the servicing-XPC progress channel (#426): decides whether
/// to push a `(bytesTransferred, totalBytes)` update to the extension now.
///
/// A multi-GB pull fires the receiver's per-chunk callback tens of thousands of
/// times; pushing every one would flood the control connection. This coalesces to
/// at most one push per ~1% of the total OR per ~100 ms, and always pushes the
/// final chunk (`bytes >= total`) so the determinate bar reaches 100% before the
/// clone step. Stateless and testable in isolation; the caller owns the
/// watermarks (`lastPushedBytes`, elapsed since the last push).
enum FetchProgressThrottle {
    /// Minimum fraction of the total that must accumulate since the last push.
    static let minByteFraction = 0.01
    /// Minimum wall-clock gap between time-triggered pushes.
    static let minInterval: TimeInterval = 0.1

    /// Whether `bytes`/`total` warrants a push given the last pushed byte count and
    /// the time since the last push.
    ///
    /// Requires strictly forward progress (`bytes > lastPushedBytes`), then pushes
    /// when it's the final chunk, when `minInterval` has elapsed, or when at least
    /// `minByteFraction` of `total` has accrued since the last push. Seed
    /// `elapsedSinceLastPush` with a large value for the first push so the bar
    /// leaves zero promptly.
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

/// Coalesces and pushes servicing-XPC progress for one in-flight relay pull (#426).
///
/// Holds the extension's control connection — captured synchronously during
/// `fetchFile`, where `NSXPCConnection.current()` is valid — and pushes throttled
/// `fetchProgressed` calls back to the extension for the pull's duration. The push
/// is one-way and best-effort: `remoteObjectProxyWithErrorHandler` swallows a
/// send failure (a dead connection is logged, never propagated), and a
/// version-skewed extension without the selector drops the message — so a missing
/// peer degrades to no-progress without tearing the connection down.
///
/// `@unchecked Sendable`: `NSXPCConnection` is thread-safe but not `Sendable`, and
/// the throttle watermarks are guarded by `lock`.
final class FetchProgressPusher: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let generation: UInt64
    private let repIndex: Int
    /// `nil` for a flat rep (pushes `fetchProgressed`); a child seq for a
    /// directory rep's file node (pushes `childFetchProgressed`, folder D1b).
    private let childSeq: UInt32?
    private let logger: KernovaLogger
    private let lock = NSLock()
    private var lastPushedBytes: UInt64 = 0
    /// When the last push was sent; `nil` until the first, so the first forward
    /// chunk always pushes (elapsed reads as effectively infinite).
    private var lastPushAt: DispatchTime?

    init(
        connection: NSXPCConnection, generation: UInt64, repIndex: Int, childSeq: UInt32? = nil,
        logger: KernovaLogger
    ) {
        self.connection = connection
        self.generation = generation
        self.repIndex = repIndex
        self.childSeq = childSeq
        self.logger = logger
    }

    /// Records cumulative progress and pushes it when the throttle allows.
    func record(bytesTransferred: UInt64, totalBytes: UInt64) {
        let now = DispatchTime.now()
        let shouldPush: Bool = lock.withLock {
            let elapsed =
                lastPushAt.map { Double(now.uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000 }
                ?? .greatestFiniteMagnitude
            guard
                FetchProgressThrottle.shouldPush(
                    bytes: bytesTransferred, total: totalBytes, lastPushedBytes: lastPushedBytes,
                    elapsedSinceLastPush: elapsed)
            else { return false }
            lastPushedBytes = bytesTransferred
            lastPushAt = now
            return true
        }
        guard shouldPush else { return }
        let control =
            connection.remoteObjectProxyWithErrorHandler { [logger] error in
                logger.debug(
                    "fetch progress push failed: \(error.localizedDescription, privacy: .public)")
            } as? FileProviderControl
        if let childSeq {
            control?.childFetchProgressed(
                generation: generation, repIndex: repIndex, childSeq: childSeq,
                bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        } else {
            control?.fetchProgressed(
                generation: generation, repIndex: repIndex,
                bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        }
    }
}
