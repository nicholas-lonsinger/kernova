import FileProvider
import Foundation

// The owner-side relay the extension calls back at `fetchContents`, plus the
// per-pull progress machinery it drives (split out of FileProviderDomainHost.swift,
// which owns registration/manifest/availability).
//
// Each relay pull feeds `ClipboardProgressTracker` — Kernova's own progress
// readout (#643, #652) — from the receiver's per-chunk `onProgress` callback, plus
// each pull's start and terminal so the tracker can aggregate many pulls into one
// session. Two earlier Finder-facing consumers of that same callback — the
// servicing-XPC push that drove the extension's `fetchContents` `Progress` (#426)
// and the published `NSProgress` Finder's copy dialog was meant to render (#634) —
// were removed by #644 after #639 found no Finder surface ever rendered them. Since
// #652 there is exactly one owner-side consumer: the same tracker drives every
// progress surface, so a paste can no longer read differently in the menu bar than
// in the clipboard window.

/// The XPC-exported relay object.
///
/// Pulls a file rep through the clipboard owner and replies with the staged-file
/// path, never the bytes.
public final class FileProviderRelayService: NSObject, FileProviderRelay {
    private let logger: KernovaLogger
    private let pullProvider: FileProviderPullProvider
    /// Runs each `fetchFile` pull, and each `cancelFetch` signal, off the XPC
    /// delivery queue.
    ///
    /// `NSXPCConnection` delivers every incoming exported-object call — including
    /// `cancelFetch` — on one private *serial* queue per connection (WWDC 2012
    /// session 241), so blocking that queue for the whole vsock pull (as `fetchFile`
    /// used to) would starve any `cancelFetch` for the very fetch it's trying to
    /// abort — and `cancelFetch` itself can block on a stalled peer's vsock write,
    /// so it needs the same treatment. Dispatching here frees the delivery queue
    /// immediately; `.concurrent` also lets independent multi-file pulls actually
    /// run in parallel, which the receiver/coordinator already support.
    private let pullQueue = DispatchQueue(
        label: "app.kernova.fileprovider.relay.pull", attributes: .concurrent)

    /// Guards the owner's wiring below, which the domain host sets from its init
    /// while the XPC queues may already read it on later pulls.
    private let wiringLock = NSLock()
    private var progressTrackerStorage: ClipboardProgressTracker?

    /// Receives each pull's start, byte counts, and terminal so the owner can
    /// render one aggregate readout for the whole paste (#643, #652).
    ///
    /// `nil` (a context that never registered a domain, e.g. most tests) simply
    /// means no readout.
    ///
    /// Every pull below captures this **once, at entry**, and reports to that
    /// tracker for its whole life. That is load-bearing on the host, where the
    /// shared File Provider domain is re-pointed at whichever VM published most
    /// recently: an in-flight pull keeps feeding the VM it started under, so a
    /// superseded VM's paste goes on rendering its own session rather than
    /// disappearing mid-transfer.
    public var progressTracker: ClipboardProgressTracker? {
        get { wiringLock.withLock { progressTrackerStorage } }
        set { wiringLock.withLock { progressTrackerStorage = newValue } }
    }

    /// Creates the relay service, logging under `loggerSubsystem`.
    public init(pullProvider: FileProviderPullProvider, loggerSubsystem: String) {
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "FileProviderRelay")
        self.pullProvider = pullProvider
        super.init()
    }

    /// Pulls `(generation, repIndex)` through the owner and replies with the
    /// staged path, or an `NSFileProviderError` on failure.
    public func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        logger.debug(
            "Relay fetchFile (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))")
        // Announced before the queue hop, so the readout can name this file from
        // the moment the pull is asked for rather than from its first byte.
        let tracker = progressTracker
        tracker?.pullBegan(generation: generation, repIndex: repIndex, childSeq: nil)
        // Off the XPC delivery queue: the File Provider read path has no 60s
        // deadline so a long block is safe, but it must not be *this* queue — see
        // `pullQueue`'s doc for why.
        pullQueue.async { [pullProvider, logger] in
            let onProgress: @Sendable (UInt64, UInt64) -> Void = { bytes, _ in
                tracker?.pullProgressed(
                    generation: generation, repIndex: repIndex, childSeq: nil,
                    bytesTransferred: bytes)
            }
            switch pullProvider.fetchStagedFile(
                generation: generation, repIndex: repIndex, onProgress: onProgress)
            {
            case .success(let path):
                tracker?.pullEnded(
                    generation: generation, repIndex: repIndex, childSeq: nil, succeeded: true)
                logger.debug("Relay staged \(path, privacy: .public)")
                reply(path, nil)
            case .failure(let error):
                tracker?.pullEnded(
                    generation: generation, repIndex: repIndex, childSeq: nil, succeeded: false)
                logger.error(
                    "Relay fetchFile failed: \(String(describing: error), privacy: .public)")
                reply(nil, Self.nsError(for: error))
            }
        }
    }

    /// Relays a best-effort cancel to the owner's pull provider.
    ///
    /// Dispatched onto `pullQueue`, the same as `fetchFile`, rather than run
    /// directly on the connection's serial delivery queue: `cancelStagedPull`
    /// bottoms out in a vsock write (`ClipboardStreamReceiver.cancel(transferID:)`
    /// sending a `ClipboardStreamAbort`) that can block for real time against a
    /// stalled peer, and this delivery queue is shared with every other
    /// `fetchFile`/`cancelFetch` on the connection — blocking it here would
    /// reintroduce exactly the starvation problem moving `fetchFile` off the
    /// queue was meant to solve. (No readout teardown here: the abort surfaces
    /// as the in-flight pull's failure reply, whose branch reports the terminal
    /// to the materialization tracker.)
    public func cancelFetch(generation: UInt64, repIndex: Int) {
        logger.debug(
            "Relay cancelFetch (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))"
        )
        pullQueue.async { [pullProvider] in
            pullProvider.cancelStagedPull(generation: generation, repIndex: repIndex)
        }
    }

    /// Pulls one child file of a directory rep's placeholder tree through the
    /// owner and replies with the staged path (folder D1b).
    ///
    /// Mirrors `fetchFile`.
    public func fetchChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        logger.debug(
            "Relay fetchChild (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public), seq=\(childSeq, privacy: .public))"
        )
        let tracker = progressTracker
        tracker?.pullBegan(generation: generation, repIndex: repIndex, childSeq: childSeq)
        pullQueue.async { [pullProvider, logger] in
            let onProgress: @Sendable (UInt64, UInt64) -> Void = { bytes, _ in
                tracker?.pullProgressed(
                    generation: generation, repIndex: repIndex, childSeq: childSeq,
                    bytesTransferred: bytes)
            }
            switch pullProvider.fetchStagedChild(
                generation: generation, repIndex: repIndex, childSeq: childSeq,
                relativePath: relativePath, onProgress: onProgress)
            {
            case .success(let path):
                tracker?.pullEnded(
                    generation: generation, repIndex: repIndex, childSeq: childSeq,
                    succeeded: true)
                logger.debug("Relay staged child \(path, privacy: .public)")
                reply(path, nil)
            case .failure(let error):
                tracker?.pullEnded(
                    generation: generation, repIndex: repIndex, childSeq: childSeq,
                    succeeded: false)
                logger.error(
                    "Relay fetchChild failed: \(String(describing: error), privacy: .public)")
                reply(nil, Self.nsError(for: error))
            }
        }
    }

    /// Relays a best-effort child-fetch cancel to the owner's pull provider.
    public func cancelChildFetch(generation: UInt64, repIndex: Int, childSeq: UInt32) {
        logger.debug(
            "Relay cancelChildFetch (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public), seq=\(childSeq, privacy: .public))"
        )
        pullQueue.async { [pullProvider] in
            pullProvider.cancelStagedChildPull(
                generation: generation, repIndex: repIndex, childSeq: childSeq)
        }
    }

    private static func nsError(for error: FileProviderPullError) -> NSError {
        let code: NSFileProviderError.Code
        switch error {
        case .noCurrentOffer: code = .noSuchItem
        case .pullFailed: code = .serverUnreachable
        }
        return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)
    }
}

// MARK: - Progress throttle

/// Pure throttle for a pull's per-chunk progress consumers: decides whether to
/// forward a `(bytesTransferred, totalBytes)` update now.
///
/// A multi-GB pull fires the receiver's per-chunk callback tens of thousands of
/// times; forwarding every one would flood a consumer's main-queue republishes.
/// This coalesces to at most one update per ~1% of the total OR per ~100 ms, and
/// always forwards the final chunk (`bytes >= total`) so a determinate readout
/// always reaches 100% rather than stalling one throttle interval short.
/// Stateless and testable in isolation; the caller owns the watermarks
/// (`lastPushedBytes`, elapsed since the last push).
public enum FetchProgressThrottle {
    /// Minimum fraction of the total that must accumulate since the last push.
    public static let minByteFraction = 0.01
    /// Minimum wall-clock gap between time-triggered pushes.
    public static let minInterval: TimeInterval = 0.1

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

/// The stateful half of the throttle: owns one consumer's watermarks and
/// answers "forward this update?" under its own lock.
///
/// `FetchProgressThrottle` is the pure decision; this is the per-consumer
/// bookkeeping around it (last-forwarded byte count and elapsed since the last
/// forward). `ClipboardProgressTracker` holds one per *session* — the aggregate
/// is a single byte stream even when several transfers feed it — so every
/// progress surface republishes at one shared policy and none can drift.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`.
public final class FetchProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastForwardedBytes: UInt64 = 0
    /// When the last update was forwarded; `nil` until the first, so the first
    /// forward chunk always passes (elapsed reads as effectively infinite).
    private var lastForwardAt: DispatchTime?

    /// Creates a coalescer with empty watermarks, so its first forward-progress
    /// update always passes.
    public init() {}

    /// Records that an update was forwarded without asking `shouldForward` —
    /// a consumer that bypasses the throttle for something the user must see
    /// (a reveal, a terminal, an item finishing).
    ///
    /// Without this the watermarks would still describe the last *throttled*
    /// forward, so the very next update would measure its delta from a byte
    /// count that is already on screen and sail through the policy no matter how
    /// small it was.
    public func markForwarded(bytesTransferred: UInt64) {
        lock.withLock {
            lastForwardedBytes = max(lastForwardedBytes, bytesTransferred)
            lastForwardAt = DispatchTime.now()
        }
    }

    /// Whether `(bytesTransferred, totalBytes)` should be forwarded now,
    /// advancing the watermarks when it should.
    public func shouldForward(bytesTransferred: UInt64, totalBytes: UInt64) -> Bool {
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
