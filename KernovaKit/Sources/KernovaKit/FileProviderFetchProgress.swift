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

/// Owns the watermarks `FetchProgressThrottle` decides against, so an in-flight
/// pull's per-chunk byte counts turn into an emit/skip verdict with one call.
///
/// `FetchProgressThrottle` is deliberately pure — it takes `lastPushedBytes` and
/// `elapsedSinceLastPush` as arguments — which leaves every consumer needing the
/// same lock, the same two watermarks, and the same "the first call reads as
/// infinite elapsed so the bar leaves zero promptly" seeding. Two consumers now
/// coalesce the same callback (`FetchProgressPusher`'s servicing-XPC push and
/// `PublishedFetchProgress`'s Finder-facing publication), so that bookkeeping
/// lives here once instead of being duplicated per consumer.
///
/// One instance tracks one in-flight pull; consumers never share one.
///
/// `@unchecked Sendable`: the watermarks are guarded by `lock`, and the pull's
/// per-chunk callback fires off-main on the transfer's receive lane.
final class FetchProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmittedBytes: UInt64 = 0
    /// When the last emit was allowed; `nil` until the first, so the first
    /// forward chunk always emits (elapsed reads as effectively infinite).
    private var lastEmitAt: DispatchTime?

    /// Whether `bytes`/`total` should be emitted now, recording the watermarks
    /// when it says yes.
    ///
    /// `now` is injectable so a test can drive the time bound deterministically
    /// instead of sleeping.
    func shouldEmit(bytes: UInt64, total: UInt64, now: DispatchTime = .now()) -> Bool {
        lock.withLock {
            let elapsed =
                lastEmitAt.map { Double(now.uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000 }
                ?? .greatestFiniteMagnitude
            guard
                FetchProgressThrottle.shouldPush(
                    bytes: bytes, total: total, lastPushedBytes: lastEmittedBytes,
                    elapsedSinceLastPush: elapsed)
            else { return false }
            lastEmittedBytes = bytes
            lastEmitAt = now
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
/// What this drives is the extension's `fetchContents` `Progress`, and so the
/// File Provider item's own download badge. It is *not* what Finder's copy dialog
/// renders — fileproviderd does not bridge a third-party extension's
/// `fetchContents` `Progress` into that dialog on macOS 26 (verified live, #634);
/// `PublishedFetchProgress` below covers the dialog.
///
/// `@unchecked Sendable`: `NSXPCConnection` is thread-safe but not `Sendable`, and
/// the throttle watermarks live in the lock-guarded `coalescer`.
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
        guard coalescer.shouldEmit(bytes: bytesTransferred, total: totalBytes) else { return }
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

// MARK: - Finder-visible published progress

/// How a published progress reaches other processes.
///
/// Injected so a unit test never registers a real cross-process progress with
/// the system — `Progress.publish()` hands the object to a system-wide registry
/// other applications subscribe to, which a test bundle has no business doing.
/// Both closures are called only on the main queue; that confinement is what
/// makes handing a non-`Sendable` `Progress` across them sound, and it is why
/// `PublishedFetchProgress` can be `@unchecked Sendable` while owning one.
struct ProgressPublication: Sendable {
    /// Registers `progress` with the system so subscribers can observe it.
    var publish: @Sendable (Progress) -> Void
    /// Withdraws a previously published `progress`.
    var unpublish: @Sendable (Progress) -> Void

    /// The real cross-process publication.
    static let system = ProgressPublication(
        publish: { $0.publish() }, unpublish: { $0.unpublish() })
}

/// Publishes a cross-process `NSProgress` for one in-flight relay pull, so
/// Finder's copy dialog renders a determinate download bar instead of the
/// indeterminate "Preparing to copy…" slide (#634).
///
/// The `Progress` the extension returns from `fetchContents` is *not* what that
/// dialog consumes: verified live on macOS 26, ours is byte-denominated,
/// `isIndeterminate == false`, and advances 0→100 % over the whole transfer while
/// the dialog stays indeterminate the entire time — fileproviderd does not bridge
/// a third-party extension's fetch progress into the copy UI. What Finder *does*
/// consume is a published progress keyed to the source file's URL
/// (`Progress.addSubscriber(forFileURL:)` machinery): `kind = .file`,
/// `fileOperationKind = .downloading`, `.fileURLKey` = the placeholder's
/// user-visible URL under `~/Library/CloudStorage/…`, `totalUnitCount` = the byte
/// count. This type publishes exactly that from the owner process for the pull's
/// duration. Because the owner-side relay is shared, both directions — the host
/// app's guest→host "Copy to Mac" and the guest agent's host→guest paste — are
/// covered by the one implementation.
///
/// Nothing is published until a `record` lands at least `revealDelay` after the
/// first one, mirroring the in-app transfer bar's reveal (see
/// `VsockClipboardService.defaultProgressRevealDelay`). The cost of that gate is
/// that a transfer which stalls immediately after its first chunk never shows a
/// bar at all — but that is exactly today's behavior, so it is not a regression,
/// and it buys two things: an instant transfer never flashes a bar into the
/// dialog, and a folder copy (whose every child is fetched through its own pull)
/// doesn't pay a publish/unpublish cross-process round-trip per small child.
///
/// `@unchecked Sendable`: `Progress` is not `Sendable`, so the `Progress` itself,
/// the `finished` latch, and the `publication` closures that touch it are
/// main-queue state — every mutation, `publish()`, and `unpublish()` hop to the
/// main queue (publish/subscribe needs a run loop). The off-main reveal/coalesce
/// state is guarded by `lock`; `fileURL`, `logger`, `onCancel`, and `revealDelay`
/// are immutable `let`s.
final class PublishedFetchProgress: @unchecked Sendable {
    /// How long a pull must keep reporting before its bar is published.
    ///
    /// RATIONALE: matches the in-app transfer bar's reveal delay
    /// (`VsockClipboardService.defaultProgressRevealDelay`) so the two
    /// indicators appear together, but is defined here rather than read from the
    /// app target — `KernovaKit` is the shared layer the guest agent also links,
    /// and it must not depend on the host app.
    static let defaultRevealDelay: TimeInterval = 0.3

    private let fileURL: URL
    private let logger: KernovaLogger
    /// Invoked when a subscriber (Finder's dialog) cancels through the published
    /// progress; `nil` leaves the progress non-cancellable.
    private let onCancel: (@Sendable () -> Void)?
    private let publication: ProgressPublication
    private let revealDelay: TimeInterval
    /// Rate-limits the published bar to the same ~1 %-or-100 ms cadence as the
    /// servicing-XPC push, instead of the raw ~2,600-per-second chunk rate.
    private let coalescer = FetchProgressCoalescer()
    /// Guards `firstRecordAt`, which the pull's off-main per-chunk callback both
    /// reads and writes.
    private let lock = NSLock()
    /// When the first non-empty `record` arrived; the reveal gate measures from
    /// here.
    private var firstRecordAt: DispatchTime?

    // MARK: Main-queue state

    /// The published progress, `nil` before the reveal and after `finish()`.
    private var progress: Progress?
    /// Latched by `finish()` so a `record` hop that lands afterwards can't
    /// publish a bar nothing will ever withdraw.
    private var finished = false

    /// Creates a publisher for the pull materializing `fileURL`.
    ///
    /// `publication` and `revealDelay` are the test seams — production takes the
    /// system publication and the 300 ms reveal.
    init(
        fileURL: URL,
        logger: KernovaLogger,
        onCancel: (@Sendable () -> Void)?,
        publication: ProgressPublication = .system,
        revealDelay: TimeInterval = PublishedFetchProgress.defaultRevealDelay
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.onCancel = onCancel
        self.publication = publication
        self.revealDelay = revealDelay
    }

    /// Records the pull's cumulative byte counts, publishing or advancing the bar
    /// when the reveal gate and the coalescer both allow.
    ///
    /// Fed from the same per-chunk `onProgress` the `FetchProgressPusher` gets:
    /// off-main, once per chunk, so everything before the main-queue hop stays
    /// cheap.
    func record(bytesTransferred: UInt64, totalBytes: UInt64) {
        // A pull with no announced total can't drive a determinate bar, and a
        // zero-total progress would render as the very indeterminate slide this
        // exists to replace.
        guard totalBytes > 0 else { return }
        let now = DispatchTime.now()
        let revealed: Bool = lock.withLock {
            guard let firstRecordAt else {
                self.firstRecordAt = now
                return false
            }
            let elapsed =
                Double(now.uptimeNanoseconds - firstRecordAt.uptimeNanoseconds) / 1_000_000_000
            return elapsed >= revealDelay
        }
        guard revealed,
            coalescer.shouldEmit(bytes: bytesTransferred, total: totalBytes, now: now)
        else { return }
        DispatchQueue.main.async { [self] in
            applyOnMain(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        }
    }

    /// Unpublishes the progress, if one was ever published.
    ///
    /// Idempotent and safe before the reveal gate ever fired, so the relay can
    /// call it from a single `defer` covering the pull's success, failure, and
    /// cancel exits alike.
    func finish() {
        DispatchQueue.main.async { [self] in
            // A second `finish()` — and a `finish()` for a pull that never
            // published — stops here; both are ordinary, since the relay's
            // `defer` fires on every exit including the ones that never revealed.
            guard !finished else { return }
            finished = true
            guard let progress else { return }
            self.progress = nil
            publication.unpublish(progress)
            logger.debug(
                "Unpublished Finder progress for \(self.fileURL.path, privacy: .public)")
        }
    }

    /// Publishes the progress on the first revealed update and advances it on
    /// every later one.
    ///
    /// A `record` hop and a `finish` hop can be enqueued in either order, but
    /// both land on the main queue and so serialize: this side refuses to publish
    /// once `finished` latched, and `finish()` refuses to unpublish twice — so
    /// whichever order they run in, the progress is published at most once and
    /// withdrawn exactly once.
    private func applyOnMain(bytesTransferred: UInt64, totalBytes: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !finished else { return }
        let total = Int64(clamping: totalBytes)
        if let progress {
            progress.completedUnitCount = min(Int64(clamping: bytesTransferred), total)
            return
        }
        // RATIONALE: the explicit `parent:`/`userInfo:` initializer, never
        // `Progress(totalUnitCount:)`. The latter implicitly attaches the new
        // progress as a child of whatever `Progress.current()` happens to be on
        // the creating thread; the main queue during a paste is exactly where an
        // ambient progress can exist, and being adopted would both mis-report
        // into that parent and stop this one from being published in its own
        // right.
        let progress = Progress(
            parent: nil,
            userInfo: [
                .fileURLKey: fileURL,
                .fileOperationKindKey: Progress.FileOperationKind.downloading,
            ])
        // Apple requires `kind`, the file-operation kind, and the file URL to be
        // set BEFORE `publish()` — a subscriber matches on them at subscription
        // time, so a progress published bare is never routed to Finder's dialog.
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.totalUnitCount = total
        progress.completedUnitCount = min(Int64(clamping: bytesTransferred), total)
        // Publish/subscribe propagates a subscriber's cancel back to the
        // publisher, so a cancel from Finder's dialog must actually abort the
        // vsock pull rather than silently orphan it.
        progress.isCancellable = onCancel != nil
        progress.cancellationHandler = onCancel
        publication.publish(progress)
        self.progress = progress
        logger.debug(
            "Published Finder progress for \(self.fileURL.path, privacy: .public) (\(totalBytes, privacy: .public) bytes)"
        )
    }
}
