import Foundation

/// Aggregates a paste's File Provider materialization pulls into the single
/// progress readout the status item renders (#643).
///
/// The relay (`FileProviderRelayService`) sees one pull per file — a flat rep, or
/// one node of a folder's placeholder tree — and each carries only its *own*
/// byte counts. This turns that stream into one per-paste readout: the published
/// manifest supplies the denominators (how many files will materialize — flat
/// reps and folder file nodes alike — and how many bytes in total), the pull
/// events supply the numerators, and the result is identical whether the pulls
/// run sequentially (Finder walks a flat multi-file paste one at a time) or
/// concurrently (a folder's children overlap).
///
/// Lifecycle of one *session* — the tracker's unit of work, spanning a whole
/// paste rather than a pull:
///
/// - **Starts** at the first pull for the currently published offer. Nothing is
///   shown yet.
/// - **Reveals** once it has been running for `revealDelay`, evaluated on each
///   event rather than from a timer, so a paste that finishes inside the gate
///   never flashes UI. (Same shape as `FetchProgressFilePublisher`'s gate: a
///   streaming pull delivers events continuously, so the first one past the gate
///   reveals within a throttle interval, while a paste stalled before its first
///   byte honestly shows nothing rather than a frozen bar.)
/// - **Ends** `idleLinger` after the last pull finishes — whether that left every
///   item materialized or not. That dwell is what bridges Finder's gap between
///   two sequentially-pulled items (so a five-file paste reads as one continuous
///   transfer instead of five flickers), and it doubles as the beat that leaves
///   the finished readout on screen before it clears. A cancelled paste, or a
///   partial materialization such as dragging one file out of a folder, ends the
///   same way — below 100 %, by design.
/// - **Superseded** immediately by a new publish, an offer clear, or teardown.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`. It must
/// stay lock-based rather than `@MainActor`, because the guest agent drives it
/// from its main-queue-confined (but non-`@MainActor`) callbacks while the host
/// app drives it from the main actor, and the relay drives both off-main from
/// its XPC queues.
final class PasteMaterializationTracker: @unchecked Sendable {
    /// How long a paste must have been materializing before its progress shows.
    ///
    /// Deliberately far longer than the in-app clipboard bar's 300 ms
    /// convention: a status-item ring plus a dropdown that opens itself is a
    /// heavier interruption than a bar inside a window the user is already
    /// looking at, so it is reserved for transfers long enough (several
    /// seconds at minimum) to genuinely need a standing readout.
    static let defaultRevealDelay: TimeInterval = 5.0

    /// How long the readout stays up after the last pull finishes — the gap
    /// bridge and completion dwell described in the type's documentation.
    static let defaultIdleLinger: TimeInterval = 2.0

    /// Addresses one pull the way the relay does: a flat rep has no `childSeq`,
    /// a folder's tree node carries its own.
    struct PullUnit: Hashable {
        let repIndex: Int
        let childSeq: UInt32?
    }

    /// The denominators for the currently published offer, derived from the
    /// manifest the enumerator serves.
    private struct Offer {
        let generation: UInt64
        let sourceName: String
        /// Bytes each pull is expected to move.
        let unitBytes: [PullUnit: UInt64]
        /// The file name each pull materializes.
        let unitNames: [PullUnit: String]
        let totalBytes: UInt64

        /// How many files the paste will materialize — the "of M" the counter shows.
        ///
        /// Per *file*, not per top-level item: a folder contributes its file
        /// nodes, so a folder-only paste still gets a live counter.
        var fileCount: Int { unitBytes.count }
    }

    /// One paste's in-flight accounting.
    ///
    /// A reference type so the lock-held code mutates it in place instead of
    /// copying it back.
    private final class Session {
        let generation: UInt64
        let startedAt: TimeInterval
        /// Whether the reveal gate has been passed — once true, the readout is
        /// on screen and every terminal must clear it.
        var revealed = false
        /// Bytes observed per pull, clamped to what the manifest expects and
        /// never regressing, so the aggregate is monotonic even across a retry
        /// that restarts a pull's own count at zero.
        var unitBytes: [PullUnit: UInt64] = [:]
        var completedUnits: Set<PullUnit> = []
        /// Pulls currently in flight, in the order they began.
        ///
        /// The readout names the most recently begun one, which follows a
        /// sequential walk file by file and stays stable across a concurrent
        /// batch. (An earlier version ranked these by bytes remaining, whose
        /// tie-break pinned a folder of same-sized children to its first file
        /// for the whole paste.)
        var activeUnits: [PullUnit] = []
        /// Last file seen streaming, kept so the readout still names something
        /// during the gap between two items and at the completion dwell.
        var lastActiveName: String?
        /// This session's share of the shared republish-rate bound — the same
        /// `FetchProgressThrottle` policy the File Provider pull's other
        /// progress consumers use.
        ///
        /// One per session, because the aggregate is a single byte stream even
        /// when several pulls feed it.
        let coalescer = FetchProgressCoalescer()
        var rate = TransferRateEstimator()
        /// Bumped whenever a pull begins, so an already-scheduled idle terminal
        /// can tell it was superseded.
        var idleEpoch: UInt64 = 0

        init(generation: UInt64, startedAt: TimeInterval) {
            self.generation = generation
            self.startedAt = startedAt
        }
    }

    private let lock = NSLock()
    private var offer: Offer?
    private var session: Session?

    private let revealDelay: TimeInterval
    private let idleLinger: TimeInterval
    /// Monotonic seconds.
    ///
    /// Injected so tests drive the reveal gate and rate estimate
    /// deterministically instead of sleeping.
    private let now: @Sendable () -> TimeInterval
    /// Runs `work` after a delay — the idle terminal's only trigger, since by
    /// definition no further pull event arrives to drive it.
    ///
    /// Injected so tests fire it explicitly.
    private let schedule: @Sendable (_ after: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void
    /// Publishes a snapshot, or `nil` when the readout must clear.
    ///
    /// Called outside `lock`.
    private let emit: @Sendable (PasteMaterializationSnapshot?) -> Void

    /// Creates a tracker publishing through `emit`.
    ///
    /// `now` and `schedule` default to the system monotonic clock and the main
    /// queue; tests inject their own so no wait is ever timing-based.
    init(
        revealDelay: TimeInterval = PasteMaterializationTracker.defaultRevealDelay,
        idleLinger: TimeInterval = PasteMaterializationTracker.defaultIdleLinger,
        now: @escaping @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = {
            after, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
        },
        emit: @escaping @Sendable (PasteMaterializationSnapshot?) -> Void
    ) {
        self.revealDelay = revealDelay
        self.idleLinger = idleLinger
        self.now = now
        self.schedule = schedule
        self.emit = emit
    }

    // MARK: - Offer lifecycle

    /// Adopts the manifest just published as the current paste's denominators.
    ///
    /// Any live session is superseded: the manifest it was measured against is
    /// no longer the one the enumerator serves, so its in-flight pulls belong to
    /// an offer that has been replaced.
    func offerPublished(_ manifest: FileProviderManifest, sourceName: String) {
        var unitBytes: [PullUnit: UInt64] = [:]
        var unitNames: [PullUnit: String] = [:]
        var totalBytes: UInt64 = 0

        for item in manifest.items {
            let unit = PullUnit(repIndex: item.repIndex, childSeq: nil)
            unitBytes[unit] = item.byteCount
            unitNames[unit] = item.filename
            totalBytes &+= item.byteCount
        }
        for folder in manifest.folders {
            for node in folder.nodes where node.kind == .file {
                let unit = PullUnit(repIndex: folder.repIndex, childSeq: node.childSeq)
                unitBytes[unit] = node.byteCount
                unitNames[unit] = node.filename
                totalBytes &+= node.byteCount
            }
        }

        let published = Offer(
            generation: manifest.generation, sourceName: sourceName, unitBytes: unitBytes,
            unitNames: unitNames, totalBytes: totalBytes)
        let hadVisibleSession = lock.withLock { () -> Bool in
            let wasVisible = session?.revealed ?? false
            offer = published
            session = nil
            return wasVisible
        }
        if hadVisibleSession { emit(nil) }
    }

    /// Drops the current offer and any session measured against it — a
    /// supersession, an offer release, or teardown.
    func offerCleared() {
        let hadVisibleSession = lock.withLock { () -> Bool in
            let wasVisible = session?.revealed ?? false
            offer = nil
            session = nil
            return wasVisible
        }
        if hadVisibleSession { emit(nil) }
    }

    // MARK: - Pull events

    /// Records that a pull started, starting the session if this is the paste's
    /// first.
    func pullBegan(generation: UInt64, repIndex: Int, childSeq: UInt32?) {
        apply(generation: generation, repIndex: repIndex, childSeq: childSeq) {
            offer, session, unit in
            if !session.activeUnits.contains(unit) { session.activeUnits.append(unit) }
            session.lastActiveName = offer.unitNames[unit] ?? session.lastActiveName
            // A pull in flight means the paste isn't idle: invalidate any
            // terminal already scheduled for the gap this pull just filled.
            session.idleEpoch &+= 1
            return false
        }
    }

    /// Records a pull's cumulative byte count.
    func pullProgressed(
        generation: UInt64, repIndex: Int, childSeq: UInt32?, bytesTransferred: UInt64
    ) {
        apply(generation: generation, repIndex: repIndex, childSeq: childSeq) {
            offer, session, unit in
            // Clamped to what the manifest expects and monotonic per pull, so
            // the aggregate can never regress — including across a retry, whose
            // own count restarts at zero.
            let expected = offer.unitBytes[unit] ?? 0
            let observed = min(bytesTransferred, expected)
            session.unitBytes[unit] = max(session.unitBytes[unit] ?? 0, observed)
            // Deliberately does NOT touch `activeUnits`: what is in flight is
            // owned by `pullBegan`/`pullEnded` alone. A chunk callback fires on
            // the receiver's own lane, so one can land *after* the pull it
            // belongs to has already replied — and adding the unit back here
            // would leave the paste permanently "active", so the idle terminal
            // would never fire and the readout would stick on screen forever.
            return false
        }
    }

    /// Records a pull's terminal, crediting a successful one in full and
    /// arming the idle terminal once nothing is left in flight.
    func pullEnded(generation: UInt64, repIndex: Int, childSeq: UInt32?, succeeded: Bool) {
        apply(generation: generation, repIndex: repIndex, childSeq: childSeq) {
            offer, session, unit in
            session.activeUnits.removeAll { $0 == unit }
            if succeeded {
                session.completedUnits.insert(unit)
                // Credit the manifest's full byte count: the throttle can have
                // suppressed the final chunks, and a completed pull must read
                // as complete.
                session.unitBytes[unit] = offer.unitBytes[unit] ?? session.unitBytes[unit] ?? 0
            }
            // A failed pull keeps whatever it moved (those bytes really did
            // cross) but never counts its item complete.
            return true
        }
    }

    /// Shared event path: resolves the unit against the current offer, mutates
    /// the session, then decides what to publish.
    ///
    /// `mutate` returns whether this event may have left the paste idle, which
    /// is the only case that needs the scheduled terminal.
    private func apply(
        generation: UInt64, repIndex: Int, childSeq: UInt32?,
        _ mutate: (Offer, Session, PullUnit) -> Bool
    ) {
        enum Outcome {
            case ignored
            case updated(PasteMaterializationSnapshot?)
            case armIdleTerminal(epoch: UInt64, snapshot: PasteMaterializationSnapshot?)
        }

        let outcome: Outcome = lock.withLock {
            // A pull for a superseded generation, or for a unit this offer never
            // published, contributes to no paste we are measuring.
            guard let offer, offer.generation == generation else { return .ignored }
            let unit = PullUnit(repIndex: repIndex, childSeq: childSeq)
            guard offer.unitBytes[unit] != nil else { return .ignored }

            let session = self.session ?? Session(generation: generation, startedAt: now())
            self.session = session
            let mayBeIdle = mutate(offer, session, unit)
            let snapshot = evaluate(offer: offer, session: session)
            guard mayBeIdle, session.activeUnits.isEmpty else { return .updated(snapshot) }
            return .armIdleTerminal(epoch: session.idleEpoch, snapshot: snapshot)
        }

        switch outcome {
        case .ignored:
            return
        case .updated(let snapshot):
            if let snapshot { emit(snapshot) }
        case .armIdleTerminal(let epoch, let snapshot):
            if let snapshot { emit(snapshot) }
            schedule(idleLinger) { [weak self] in
                self?.idleTerminalFired(generation: generation, epoch: epoch)
            }
        }
    }

    /// Ends a session that has stayed idle for the whole linger.
    private func idleTerminalFired(generation: UInt64, epoch: UInt64) {
        let shouldClear = lock.withLock { () -> Bool in
            guard let session, session.generation == generation, session.idleEpoch == epoch,
                session.activeUnits.isEmpty
            else { return false }
            self.session = nil
            return session.revealed
        }
        if shouldClear { emit(nil) }
    }

    // MARK: - Snapshot

    /// Folds the session's state into a snapshot, returning `nil` when this
    /// event shouldn't reach the UI.
    ///
    /// Only the reveal bypasses the shared throttle; everything else — the
    /// per-file counter included — rides the coalescer at the shared
    /// ~1 %/100 ms policy, since a folder can complete thousands of small
    /// files faster than a screen is worth repainting. The paste's own final
    /// update is still never lost: a completed pull is credited its full
    /// manifest byte count, and the throttle's final-chunk rule always admits
    /// the update that reaches the total. Caller holds `lock`.
    private func evaluate(offer: Offer, session: Session) -> PasteMaterializationSnapshot? {
        let transferred = session.unitBytes.values.reduce(UInt64(0)) { $0 &+ $1 }
        let sampledAt = now()
        session.rate.record(bytes: transferred, seconds: sampledAt)

        if !session.revealed {
            guard sampledAt - session.startedAt >= revealDelay else { return nil }
            session.revealed = true
            // The reveal bypassed the throttle, so its watermarks must still
            // reflect what just went on screen — otherwise the next update
            // would measure its delta from a byte count already shown.
            session.coalescer.markForwarded(bytesTransferred: transferred)
        } else {
            guard
                session.coalescer.shouldForward(
                    bytesTransferred: transferred, totalBytes: offer.totalBytes)
            else { return nil }
        }

        if let current = session.activeUnits.last, let name = offer.unitNames[current] {
            session.lastActiveName = name
        }

        return PasteMaterializationSnapshot(
            sourceName: offer.sourceName,
            currentItemName: session.lastActiveName,
            filesCompleted: session.completedUnits.count,
            fileCount: offer.fileCount,
            bytesTransferred: min(transferred, offer.totalBytes),
            totalBytes: offer.totalBytes,
            bytesPerSecond: session.rate.bytesPerSecond,
            secondsRemaining: session.rate.secondsRemaining(
                bytes: transferred, total: offer.totalBytes))
    }
}
