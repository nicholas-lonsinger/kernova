import FileProvider
import Foundation

// The owner-side relay the extension calls back at `fetchContents`, plus the
// per-pull progress machinery it drives (split out of FileProviderDomainHost.swift,
// which owns registration/manifest/availability).
//
// One relay pull feeds two progress consumers, both from the same per-chunk
// `onProgress` callback:
//  1. `FetchProgressPusher` — servicing-XPC pushes that drive the extension's
//     byte-denominated `fetchContents` `Progress` (#426).
//  2. `FetchProgressFilePublisher` — a cross-process published `NSProgress`
//     keyed by the placeholder's user-visible URL, which is what Finder's copy
//     dialog actually renders (#634); the `fetchContents` `Progress` alone does
//     not reach that dialog on macOS 26.

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

    /// Guards `visibleFileURLResolver`, which the domain host sets from its init
    /// while the XPC queues may already read it on later pulls.
    private let resolverLock = NSLock()
    private var visibleFileURLResolverStorage:
        (@Sendable (_ generation: UInt64, _ repIndex: Int, _ childSeq: UInt32?) -> URL?)?

    /// Resolves an in-flight pull's placeholder to its user-visible URL — the
    /// key the published Finder-copy-dialog progress is filed under (#634).
    ///
    /// `childSeq` is `nil` for a flat rep, or the tree node for a directory
    /// rep's child (folder D1b). **Called on the main queue only** (the domain
    /// host's implementation reads its main-queue `rootURL`). `nil` (unset, or
    /// no URL resolves) degrades to no published progress — the pull itself is
    /// unaffected.
    var visibleFileURLResolver: (@Sendable (_ generation: UInt64, _ repIndex: Int, _ childSeq: UInt32?) -> URL?)?
    {
        get { resolverLock.withLock { visibleFileURLResolverStorage } }
        set { resolverLock.withLock { visibleFileURLResolverStorage = newValue } }
    }

    #if DEBUG
    /// Guards `lastFilePublisherForTesting` (written on the XPC caller's thread,
    /// read by tests).
    private let lastFilePublisherLock = NSLock()
    private var lastFilePublisherStorage: FetchProgressFilePublisher?
    /// Test-only handle to the most recent pull's file-progress publisher, so a
    /// test can observe the publish/unpublish lifecycle `fetchFile` drives.
    var lastFilePublisherForTesting: FetchProgressFilePublisher? {
        lastFilePublisherLock.withLock { lastFilePublisherStorage }
    }
    #endif

    /// How long a pull streams before its published file progress reveals;
    /// injected only by tests (production keeps the publisher's default).
    private let fileProgressRevealDelay: TimeInterval

    /// Creates the relay service, logging under `loggerSubsystem`.
    ///
    /// `fileProgressRevealDelay` is the published file progress's reveal gate —
    /// tests inject 0 so a mock pull's instant chunks still publish; `nil` (the
    /// default, a sentinel because the internal constant can't appear in a
    /// public default argument) keeps `FetchProgressFilePublisher.defaultRevealDelay`.
    public init(
        pullProvider: FileProviderPullProvider, loggerSubsystem: String,
        fileProgressRevealDelay: TimeInterval? = nil
    ) {
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "FileProviderRelay")
        self.pullProvider = pullProvider
        self.fileProgressRevealDelay =
            fileProgressRevealDelay ?? FetchProgressFilePublisher.defaultRevealDelay
        super.init()
    }

    /// Builds the published-progress handle for one pull, or `nil` when no
    /// resolver is wired (a context that never registered a domain, e.g. tests).
    private func makeFilePublisher(
        generation: UInt64, repIndex: Int, childSeq: UInt32?
    ) -> FetchProgressFilePublisher? {
        guard let resolver = visibleFileURLResolver else { return nil }
        let publisher = FetchProgressFilePublisher(
            resolveFileURL: { resolver(generation, repIndex, childSeq) }, logger: logger,
            revealDelay: fileProgressRevealDelay)
        #if DEBUG
        lastFilePublisherLock.withLock { lastFilePublisherStorage = publisher }
        #endif
        return publisher
    }

    /// Pulls `(generation, repIndex)` through the owner and replies with the
    /// staged path, or an `NSFileProviderError` on failure.
    public func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        logger.debug(
            "Relay fetchFile (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))")
        // Capture the calling connection SYNCHRONOUSLY — `NSXPCConnection.current()`
        // is valid only during this incoming invocation, before we hop to
        // `pullQueue`. The pusher then drives determinate progress back to the
        // extension for the pull's duration (#426). `nil` outside XPC (unit tests
        // call `fetchFile` directly) → no pushes, a no-op.
        let pusher = NSXPCConnection.current().map {
            FetchProgressPusher(
                connection: $0, generation: generation, repIndex: repIndex, logger: logger)
        }
        let filePublisher = makeFilePublisher(
            generation: generation, repIndex: repIndex, childSeq: nil)
        // Off the XPC delivery queue: the File Provider read path has no 60s
        // deadline so a long block is safe, but it must not be *this* queue — see
        // `pullQueue`'s doc for why.
        pullQueue.async { [pullProvider, logger] in
            let onProgress: @Sendable (UInt64, UInt64) -> Void = { bytes, total in
                pusher?.record(bytesTransferred: bytes, totalBytes: total)
                filePublisher?.record(bytesTransferred: bytes, totalBytes: total)
            }
            switch pullProvider.fetchStagedFile(
                generation: generation, repIndex: repIndex, onProgress: onProgress)
            {
            case .success(let path):
                filePublisher?.finish()
                logger.debug("Relay staged \(path, privacy: .public)")
                reply(path, nil)
            case .failure(let error):
                filePublisher?.finish()
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
    /// queue was meant to solve. (No progress teardown here: the abort surfaces
    /// as the in-flight pull's failure reply, whose branch unpublishes.)
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
        let pusher = NSXPCConnection.current().map {
            FetchProgressPusher(
                connection: $0, generation: generation, repIndex: repIndex, childSeq: childSeq,
                logger: logger)
        }
        let filePublisher = makeFilePublisher(
            generation: generation, repIndex: repIndex, childSeq: childSeq)
        pullQueue.async { [pullProvider, logger] in
            let onProgress: @Sendable (UInt64, UInt64) -> Void = { bytes, total in
                pusher?.record(bytesTransferred: bytes, totalBytes: total)
                filePublisher?.record(bytesTransferred: bytes, totalBytes: total)
            }
            switch pullProvider.fetchStagedChild(
                generation: generation, repIndex: repIndex, childSeq: childSeq,
                relativePath: relativePath, onProgress: onProgress)
            {
            case .success(let path):
                filePublisher?.finish()
                logger.debug("Relay staged child \(path, privacy: .public)")
                reply(path, nil)
            case .failure(let error):
                filePublisher?.finish()
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

// MARK: - Servicing progress push

/// Pure throttle for the per-pull progress consumers (#426): decides whether to
/// forward a `(bytesTransferred, totalBytes)` update now.
///
/// A multi-GB pull fires the receiver's per-chunk callback tens of thousands of
/// times; forwarding every one would flood the control connection (the pusher)
/// or the main queue (the file publisher). This coalesces to at most one update
/// per ~1% of the total OR per ~100 ms, and always forwards the final chunk
/// (`bytes >= total`) so the determinate bar reaches 100% before the clone step.
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
/// bookkeeping around it (last-forwarded byte count, elapsed since the last
/// forward, and the first-update timestamp the file publisher's reveal gate
/// measures from). All three consumers of a pull's per-chunk progress — the
/// servicing-XPC pusher, the published-`NSProgress` file publisher, and the host
/// app's in-app transfer bar (`ClipboardTransferProgressTracker`, one coalescer
/// per tracked transfer) — share this instead of keeping parallel copies that
/// could drift apart on a policy change.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`, and
/// `onProgress` fires from the receive lane.
public final class FetchProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastForwardedBytes: UInt64 = 0
    /// When the last update was forwarded; `nil` until the first, so the first
    /// forward chunk always passes (elapsed reads as effectively infinite).
    private var lastForwardAt: DispatchTime?
    private var firstUpdateAt: DispatchTime?

    /// Creates a coalescer with empty watermarks, so its first forward-progress
    /// update always passes.
    public init() {}

    /// When the first update was recorded, or `nil` before any — the reveal
    /// gate's reference point.
    var firstUpdateTime: DispatchTime? { lock.withLock { firstUpdateAt } }

    /// Whether `(bytesTransferred, totalBytes)` should be forwarded now,
    /// advancing the watermarks when it should.
    public func shouldForward(bytesTransferred: UInt64, totalBytes: UInt64) -> Bool {
        let now = DispatchTime.now()
        return lock.withLock {
            if firstUpdateAt == nil { firstUpdateAt = now }
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
/// the throttle watermarks live in the (lock-guarded) coalescer.
final class FetchProgressPusher: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let generation: UInt64
    private let repIndex: Int
    /// `nil` for a flat rep (pushes `fetchProgressed`); a child seq for a
    /// directory rep's file node (pushes `childFetchProgressed`, folder D1b).
    private let childSeq: UInt32?
    private let logger: KernovaLogger
    private let coalescer = FetchProgressCoalescer()

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
        guard coalescer.shouldForward(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        else { return }
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

// MARK: - Published file progress (Finder's copy dialog)

/// Publishes a cross-process `NSProgress` for one in-flight relay pull, keyed by
/// the placeholder's user-visible URL — what Finder's copy dialog renders (#634).
///
/// fileproviderd does not bridge a third-party extension's `fetchContents`
/// `Progress` into Finder's copy-dialog UI on macOS 26: the dialog stays on the
/// indeterminate "Preparing to copy…" slide no matter how that `Progress`
/// advances (verified live, #634). What the dialog *does* consume is a published
/// `NSProgress` associated with the source file's URL — `kind = .file`,
/// `fileOperationKind = .downloading`, `.fileURLKey` = the placeholder's URL
/// under `~/Library/CloudStorage/…` — the same `Progress.publish()` /
/// `addSubscriber(forFileURL:)` machinery first-party providers use. So the pull
/// owner publishes one per pull, advanced from the receiver's per-chunk callback.
///
/// Lifecycle: published lazily on the first recorded chunk carrying a non-zero
/// total (resolving the URL then, not at pull start, so a pull that dies before
/// its first chunk never publishes) once `revealDelay` has elapsed since the
/// first chunk — the in-app bar's 300 ms reveal convention, so an instant
/// transfer (and a folder copy's many small children, each its own pull) never
/// flashes a publish/unpublish cycle. Advanced under the shared
/// `FetchProgressThrottle`, and `unpublish()`ed by `finish()` — called from both
/// reply branches of the pull, which also covers cancel: an aborted pull
/// surfaces as the failure reply. All `Progress` work runs on the main queue
/// (the publish/subscribe machinery needs a run-loop thread), and the sandboxed
/// host app can publish for the CloudStorage URL because the domain host holds
/// the domain root's security scope while the root is current (`adoptRootURL`).
///
/// `@unchecked Sendable`: the throttle watermarks live in the (lock-guarded)
/// coalescer; `progress`/`finished`/`resolutionFailed` are main-queue state.
final class FetchProgressFilePublisher: @unchecked Sendable {
    /// The default reveal gate: how long a pull must have been streaming before
    /// its progress publishes (the in-app bar's 300 ms convention).
    static let defaultRevealDelay: TimeInterval = 0.3

    /// Resolves the pull's placeholder to its user-visible URL.
    ///
    /// Bound to the pull's `(generation, repIndex, childSeq?)` addressing. Main
    /// queue only; `nil` degrades to no published progress.
    private let resolveFileURL: @Sendable () -> URL?
    private let logger: KernovaLogger
    /// Seconds after the first chunk before the progress may publish; a pull
    /// that finishes sooner never publishes at all.
    private let revealDelay: TimeInterval
    private let coalescer = FetchProgressCoalescer()

    // MARK: Main-queue state

    private var progress: Progress?
    /// Latched by `finish()` so a late throttled update can't publish or advance
    /// after the terminal unpublish.
    private var finished = false
    /// Latched when the resolver returns `nil` so a failed resolution isn't
    /// retried on every subsequent chunk.
    private var resolutionFailed = false

    #if DEBUG
    /// Test-only view of the published `Progress` (main-queue read), so tests
    /// can lock the publish/advance/unpublish lifecycle.
    var progressForTesting: Progress? {
        dispatchPrecondition(condition: .onQueue(.main))
        return progress
    }
    #endif

    init(
        resolveFileURL: @escaping @Sendable () -> URL?, logger: KernovaLogger,
        revealDelay: TimeInterval = FetchProgressFilePublisher.defaultRevealDelay
    ) {
        self.resolveFileURL = resolveFileURL
        self.logger = logger
        self.revealDelay = revealDelay
    }

    /// Records cumulative progress and applies it on the main queue when the
    /// throttle allows.
    func record(bytesTransferred: UInt64, totalBytes: UInt64) {
        // A total-less update can't drive a determinate bar; the throttle below
        // also enforces forward progress.
        guard totalBytes > 0 else { return }
        guard coalescer.shouldForward(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        else { return }
        DispatchQueue.main.async { [self] in
            applyOnMain(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        }
    }

    /// Tears the published progress down at the pull's terminal (either reply
    /// branch).
    ///
    /// Idempotent; a throttled update landing after this is a no-op.
    func finish() {
        DispatchQueue.main.async { [self] in
            finished = true
            guard let progress else { return }
            progress.unpublish()
            self.progress = nil
            logger.debug("Unpublished file progress")
        }
    }

    private func applyOnMain(bytesTransferred: UInt64, totalBytes: UInt64) {
        guard !finished, !resolutionFailed else { return }
        let total = Int64(clamping: totalBytes)
        let completed = Int64(clamping: bytesTransferred)
        if let progress {
            if progress.totalUnitCount != total { progress.totalUnitCount = total }
            progress.completedUnitCount = completed
            return
        }
        // The reveal gate: don't publish until the pull has streamed for
        // `revealDelay` (not latched — a later throttled update re-evaluates),
        // so a pull that finishes sooner never publishes at all.
        // RATIONALE: the gate is event-driven (re-checked per throttled chunk),
        // not timer-scheduled. A streaming pull delivers per-chunk callbacks
        // continuously, so the first update past the gate publishes within one
        // throttle interval; the only orderings a timer would change are (a) a
        // one-chunk (≤64 KiB) file, whose sole callback is also its final —
        // suppressing that flash is the gate's purpose, and before the first
        // chunk there is no total to denominate a bar in anyway — and (b) a
        // pull that stalls inside the first `revealDelay`, where a timer would
        // pin a frozen determinate bar for the stall's duration while this
        // keeps the honest indeterminate display until bytes resume (a
        // terminal stall aborts via the vsock stall timeout, whose failure
        // reply finishes this publisher).
        if let firstUpdateAt = coalescer.firstUpdateTime {
            let streaming =
                Double(DispatchTime.now().uptimeNanoseconds - firstUpdateAt.uptimeNanoseconds)
                / 1_000_000_000
            guard streaming >= revealDelay else { return }
        }
        guard let url = resolveFileURL() else {
            resolutionFailed = true
            logger.debug("File progress not published — no user-visible URL resolved")
            return
        }
        let progress = Progress(parent: nil, userInfo: [.fileURLKey: url])
        progress.kind = .file
        progress.fileOperationKind = .downloading
        // Cancellation rides the fetch path (Finder cancels its copy →
        // fileproviderd cancels `fetchContents` → `cancelFetch` aborts the pull
        // → the failure reply unpublishes), so the published proxy advertises no
        // cancel/pause of its own.
        progress.isCancellable = false
        progress.isPausable = false
        progress.totalUnitCount = total
        progress.completedUnitCount = completed
        progress.publish()
        self.progress = progress
        logger.debug("Published file progress for \(url.path, privacy: .public)")
    }
}
