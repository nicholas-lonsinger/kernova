import Foundation

/// The one authority for clipboard transfer progress, aggregating every transfer
/// of one operation into the single readout all of Kernova's progress surfaces
/// render.
///
/// A **session** is one user-visible operation, not one stream — a preview
/// fetch, a Copy to Mac, this side serving a peer's pull — opened for an opaque
/// `SessionToken` and fed per transfer. Sessions are deliberately **not** keyed
/// by generation: inbound and outbound generations are independent counters that
/// both start at 1, and a preview's generation is the paste's exactly, so any
/// generation-keyed scheme would merge unrelated operations.
///
/// A session starts at its first transfer, shows nothing until it has been
/// running for `revealDelay` (evaluated on each event, so an operation that
/// finishes inside the gate never flashes UI), and ends `idleLinger` after its
/// last transfer finishes — the dwell that bridges Finder's gap between two
/// sequentially-pulled files and leaves the finished readout on screen. A
/// cancelled or partial operation ends the same way, below 100 %, by design. A
/// teardown supersedes a session immediately, skipping the dwell.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`. It must
/// stay lock-based rather than `@MainActor` — the guest agent drives it from
/// main-queue-confined (but non-`@MainActor`) callbacks and the host app from
/// the main actor.
public final class ClipboardProgressTracker: @unchecked Sendable {
    // MARK: - Vocabulary

    /// Opaque handle to one ad-hoc session.
    public struct SessionToken: Hashable, Sendable {
        fileprivate let value: UInt64
    }

    /// One transfer a session expects, declared at open or as it starts.
    public struct PlannedUnit: Sendable {
        /// Caller-chosen identity, unique within its session.
        public let id: UInt64
        /// What the operation advertises this transfer will move — a starting
        /// figure only, revised by `unitProgressed`.
        public let expectedBytes: UInt64
        /// Display name, or `nil` for an unnamed inline payload.
        public let name: String?

        /// Declares one expected transfer.
        public init(id: UInt64, expectedBytes: UInt64, name: String? = nil) {
            self.id = id
            self.expectedBytes = expectedBytes
            self.name = name
        }
    }

    /// How long an operation must have been running before its progress shows.
    ///
    /// Uniform across every passive surface; the status-item dropdown, which
    /// interrupts by opening itself, carries its own much stricter gate in
    /// `ClipboardProgressMenuAutoOpener`.
    public static let defaultRevealDelay: TimeInterval = 0.3

    /// How long the readout stays up after the last transfer finishes.
    public static let defaultIdleLinger: TimeInterval = 2.0

    // MARK: - Internal model

    /// Addresses one transfer inside a session, by its caller-chosen id.
    private enum Unit: Hashable {
        case adHoc(UInt64)
    }

    private struct UnitState {
        /// What this transfer is expected to move; revisable by `unitProgressed`.
        var expected: UInt64
        /// Bytes seen, clamped to `expected` and never regressing, so the
        /// aggregate is monotonic even across a retry that restarts a transfer's
        /// own count at zero.
        var observed: UInt64 = 0
        var completed = false
        let name: String?
    }

    /// One operation's in-flight accounting, a reference type so the lock-held
    /// code mutates it in place instead of copying it back.
    private final class Session {
        let token: SessionToken
        let direction: ClipboardProgressSnapshot.Direction
        let peerName: String
        let isPaste: Bool
        let startedAt: TimeInterval
        /// Whether the reveal gate has been passed — once true, the readout is on
        /// screen and every terminal must clear it.
        var revealed = false
        /// Writable only through `setUnit` and `removeUnit`, which keep the
        /// running byte sums below in step with it.
        private(set) var units: [Unit: UnitState]
        var completedCount = 0
        /// Transfers currently in flight, in the order they began; the readout
        /// names the most recently begun one.
        var activeUnits: [Unit] = []
        /// Last file seen streaming, kept so the readout still names something
        /// during the gap between two transfers.
        var lastActiveName: String?
        /// This session's share of the republish-rate bound — one per session,
        /// because the aggregate is a single byte stream even when several
        /// transfers feed it.
        let coalescer = FetchProgressCoalescer()
        var rate = TransferRateEstimator()
        /// Bumped whenever a transfer begins, so an already-scheduled idle
        /// terminal can tell it was superseded.
        var idleEpoch: UInt64 = 0

        /// Bytes moved across the whole operation.
        ///
        /// A running sum rather than a reduction over `units` on demand: both
        /// totals are read on *every* event, and a folder paste holds one unit
        /// per file, so reducing would scale the hot path with the tree's size.
        private(set) var transferredBytes: UInt64 = 0
        /// Bytes the whole operation expects to move; see `transferredBytes`.
        private(set) var totalBytes: UInt64 = 0

        init(
            token: SessionToken, direction: ClipboardProgressSnapshot.Direction, peerName: String,
            isPaste: Bool, startedAt: TimeInterval, units: [Unit: UnitState]
        ) {
            self.token = token
            self.direction = direction
            self.peerName = peerName
            self.isPaste = isPaste
            self.startedAt = startedAt
            self.units = units
            for state in units.values {
                totalBytes &+= state.expected
                transferredBytes &+= state.observed
            }
        }

        /// Installs one transfer's state, keeping the running sums in step.
        func setUnit(_ unit: Unit, _ state: UnitState) {
            let previous = units[unit]
            totalBytes = totalBytes &- (previous?.expected ?? 0) &+ state.expected
            transferredBytes = transferredBytes &- (previous?.observed ?? 0) &+ state.observed
            units[unit] = state
        }

        /// Drops one transfer, unwinding everything the session counted for it.
        func removeUnit(_ unit: Unit) {
            guard let state = units.removeValue(forKey: unit) else { return }
            totalBytes &-= state.expected
            transferredBytes &-= state.observed
            if state.completed { completedCount -= 1 }
            activeUnits.removeAll { $0 == unit }
        }
    }

    /// Whether this event can have ended the operation's activity.
    private enum Activity: Equatable {
        case running
        case mayBeIdle
    }

    /// What an event decided the emitter should do, resolved under `lock` and run
    /// outside it.
    private enum Publish {
        case none
        case emit(ClipboardProgressSnapshot?)
    }

    /// Everything an event leaves for `deliver` to run once `lock` is released.
    ///
    /// `emit` and `schedule` are injected closures: calling one while holding a
    /// non-recursive lock deadlocks the moment a caller runs the work
    /// synchronously.
    private struct Outcome {
        var publish: Publish = .none
        var armIdle: (token: SessionToken, epoch: UInt64)?

        init(_ publish: Publish, armIdle: (token: SessionToken, epoch: UInt64)? = nil) {
            self.publish = publish
            self.armIdle = armIdle
        }
    }

    private let lock = NSLock()
    private var sessions: [SessionToken: Session] = [:]
    private var nextToken: UInt64 = 1
    /// Whether the last emission put something on screen, so a clear is only sent
    /// when there is something to clear.
    private var showing = false

    private let revealDelay: TimeInterval
    private let idleLinger: TimeInterval
    /// Monotonic seconds.
    private let now: @Sendable () -> TimeInterval
    /// Runs `work` after a delay — the idle terminal's only trigger, since by
    /// definition no further transfer event arrives to drive it.
    private let schedule: @Sendable (_ after: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void
    /// Publishes a snapshot, or `nil` when the readout must clear.
    ///
    /// Called outside `lock`.
    private let emit: @Sendable (ClipboardProgressSnapshot?) -> Void

    /// Creates a tracker publishing through `emit`.
    ///
    /// `now` and `schedule` default to the system monotonic clock and the main
    /// queue; tests inject their own so no wait is timing-based.
    public init(
        revealDelay: TimeInterval = ClipboardProgressTracker.defaultRevealDelay,
        idleLinger: TimeInterval = ClipboardProgressTracker.defaultIdleLinger,
        now: @escaping @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = {
            after, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
        },
        emit: @escaping @Sendable (ClipboardProgressSnapshot?) -> Void
    ) {
        self.revealDelay = revealDelay
        self.idleLinger = idleLinger
        self.now = now
        self.schedule = schedule
        self.emit = emit
    }

    // MARK: - Ad-hoc sessions

    /// Opens a session for one user-visible operation.
    ///
    /// Pre-declare every transfer in `units` where the set is known; leave it
    /// empty where the peer drives what gets pulled, and each transfer joins as
    /// `unitBegan` announces it.
    public func openSession(
        direction: ClipboardProgressSnapshot.Direction, peerName: String,
        units: [PlannedUnit] = []
    ) -> SessionToken {
        lock.withLock {
            let token = SessionToken(value: nextToken)
            nextToken &+= 1
            var table: [Unit: UnitState] = [:]
            for unit in units {
                table[.adHoc(unit.id)] = UnitState(expected: unit.expectedBytes, name: unit.name)
            }
            sessions[token] = Session(
                token: token, direction: direction, peerName: peerName, isPaste: false,
                startedAt: now(), units: table)
            return token
        }
    }

    /// Whether `token` still addresses a live session.
    ///
    /// A session ends on its own once `idleLinger` elapses with nothing in
    /// flight, so a caller that *caches* a token must ask before reusing one:
    /// events for an ended session are dropped, and a reused stale token
    /// silently measures nothing at all.
    public func isSessionLive(_ token: SessionToken) -> Bool {
        lock.withLock { sessions[token] != nil }
    }

    /// Records that one of a session's transfers started, declaring it if this is
    /// the first the session has heard of it.
    public func unitBegan(
        session token: SessionToken, id: UInt64, expectedBytes: UInt64 = 0, name: String? = nil
    ) {
        applyAdHoc(token, id: id, declaring: PlannedUnit(id: id, expectedBytes: expectedBytes, name: name)) {
            session, unit in
            if !session.activeUnits.contains(unit) { session.activeUnits.append(unit) }
            session.lastActiveName = session.units[unit]?.name ?? session.lastActiveName
            // A transfer in flight means the operation isn't idle: invalidate the
            // terminal scheduled for the gap this transfer just filled.
            session.idleEpoch &+= 1
            return .running
        }
    }

    /// Records one transfer's cumulative byte count.
    ///
    /// `totalBytes` is **wire-authoritative**: a non-zero value replaces whatever
    /// the operation advertised, because the advertised figure can be an estimate
    /// while the stream carries something else entirely — a directory rep
    /// advertises a stat-walk size and then streams a compressed archive. The
    /// advertised figure is still what gives the aggregate a denominator before
    /// the first byte arrives.
    public func unitProgressed(
        session token: SessionToken, id: UInt64, bytesTransferred: UInt64, totalBytes: UInt64 = 0
    ) {
        applyAdHoc(token, id: id, declaring: nil) { session, unit in
            guard var state = session.units[unit] else { return .running }
            if totalBytes > 0 { state.expected = totalBytes }
            state.observed = max(state.observed, min(bytesTransferred, state.expected))
            session.setUnit(unit, state)
            // Deliberately does NOT touch `activeUnits`: a chunk callback fires
            // on the transfer's own lane, so one can land *after* the transfer
            // finished, and re-adding the unit here would leave the operation
            // permanently "active" — the idle terminal would never fire and the
            // readout would stick on screen forever.
            return .running
        }
    }

    /// Records one transfer's terminal, crediting a successful one in full.
    public func unitEnded(session token: SessionToken, id: UInt64, succeeded: Bool) {
        applyAdHoc(token, id: id, declaring: nil) { session, unit in
            session.activeUnits.removeAll { $0 == unit }
            if succeeded, var state = session.units[unit] {
                if !state.completed {
                    state.completed = true
                    session.completedCount += 1
                }
                // Credit the expected byte count in full: the throttle can have
                // suppressed the final chunks, and a completed transfer must read
                // as complete.
                state.observed = state.expected
                session.setUnit(unit, state)
            }
            // A failed transfer keeps whatever it moved (those bytes really did
            // cross) but never counts its file complete.
            return .mayBeIdle
        }
    }

    /// Drops a transfer this session declared but does not own, taking it back
    /// out of the denominator.
    ///
    /// A caller that coalesces onto another session's in-flight transfer is
    /// never told when it begins, progresses, or ends. Left declared, it is a
    /// denominator waiting on events that never arrive — and `projectionLocked`
    /// ranks by bytes *remaining*, so that session wins the readout. Unknown
    /// sessions and units are ignored.
    public func discardUnit(session token: SessionToken, id: UInt64) {
        let outcome: Outcome = lock.withLock {
            guard let session = sessions[token] else { return Outcome(.none) }
            let unit = Unit.adHoc(id)
            guard session.units[unit] != nil else { return Outcome(.none) }
            session.removeUnit(unit)
            return Outcome(resolveLocked(admits: session.revealed))
        }
        deliver(outcome)
    }

    /// Ends a session the caller knows has finished — a materialization loop that
    /// has run to its end, or one abandoned partway.
    ///
    /// A revealed session still finishes through the idle linger, so its final
    /// state stays on screen for a beat. Pass `immediately: true` for a
    /// supersession or teardown, where what the readout was measuring no longer
    /// exists.
    ///
    /// **Always call this for an explicitly-opened session**, including one that
    /// never transferred anything: nothing else can know a caller's loop is over,
    /// so an unclosed session sits in the table for the process's life.
    public func closeSession(_ token: SessionToken, immediately: Bool = false) {
        let outcome: Outcome = lock.withLock {
            guard let session = sessions[token] else { return Outcome(.none) }
            // Nothing is on screen for an unrevealed session, so there is no dwell
            // to honor and no reason to keep it around.
            guard session.revealed, !immediately else {
                sessions[token] = nil
                return Outcome(resolveLocked(admits: session.revealed))
            }
            return Outcome(
                .none, armIdle: (token: token, epoch: session.idleEpoch))
        }
        deliver(outcome)
    }

    /// Drops every session and clears the readout — a teardown, where nothing the
    /// tracker was measuring can still be running.
    ///
    /// Unconditional and immediate, unlike `closeSession`: a transport that has
    /// gone away cannot finish anything, and an indicator left behind would never
    /// come down.
    public func clearAll() {
        let outcome: Outcome = lock.withLock {
            let wasShowing = showing
            sessions.removeAll()
            showing = false
            return Outcome(wasShowing ? .emit(nil) : .none)
        }
        deliver(outcome)
    }

    // MARK: - Event plumbing

    /// Shared event path.
    ///
    /// `declaring` is non-nil only for `unitBegan`, the one event allowed to
    /// introduce a transfer. Progress and terminals for an unknown transfer are
    /// dropped: a chunk landing after its session closed must never mint a new
    /// one, since nothing would arm that session's idle terminal and the readout
    /// it revealed would stick forever.
    private func applyAdHoc(
        _ token: SessionToken, id: UInt64, declaring planned: PlannedUnit?,
        _ mutate: (Session, Unit) -> Activity
    ) {
        let outcome: Outcome = lock.withLock {
            guard let session = sessions[token] else { return Outcome(.none) }
            let unit = Unit.adHoc(id)
            if session.units[unit] == nil {
                guard let planned else { return Outcome(.none) }
                session.setUnit(
                    unit, UnitState(expected: planned.expectedBytes, name: planned.name))
            }
            return mutateLocked(session: session, unit: unit, mutate)
        }
        deliver(outcome)
    }

    /// Runs a mutation against a live session and decides what to publish and
    /// whether to arm the idle terminal.
    ///
    /// Caller holds `lock`.
    private func mutateLocked(
        session: Session, unit: Unit, _ mutate: (Session, Unit) -> Activity
    ) -> Outcome {
        let activity = mutate(session, unit)
        guard activity == .mayBeIdle, session.activeUnits.isEmpty else {
            return Outcome(resolveLocked(trigger: session))
        }
        // Nothing in flight is not "finished": a multi-file paste is walked one
        // file at a time, so the gap between two of them looks exactly like the
        // end. The linger is what tells them apart.
        return Outcome(
            resolveLocked(trigger: session),
            armIdle: (token: session.token, epoch: session.idleEpoch))
    }

    /// Ends a session that has stayed idle for the whole linger.
    private func idleTerminalFired(token: SessionToken, epoch: UInt64) {
        let outcome: Outcome = lock.withLock {
            guard let session = sessions[token], session.idleEpoch == epoch,
                session.activeUnits.isEmpty
            else { return Outcome(.none) }
            sessions[token] = nil
            return Outcome(resolveLocked(admits: session.revealed))
        }
        deliver(outcome)
    }

    /// Runs an event's deferred work — the emission and the idle arming — with
    /// `lock` released.
    private func deliver(_ outcome: Outcome) {
        if case .emit(let snapshot) = outcome.publish { emit(snapshot) }
        guard let arm = outcome.armIdle else { return }
        schedule(idleLinger) { [weak self] in
            self?.idleTerminalFired(token: arm.token, epoch: arm.epoch)
        }
    }

    // MARK: - Reveal, throttle, projection

    /// Decides whether the event driving `trigger` may reach the UI, then resolves
    /// what to publish.
    ///
    /// Caller holds `lock`. Only the reveal bypasses the shared throttle;
    /// everything else — the per-file counter included — rides the coalescer,
    /// since a folder can complete thousands of small files faster than a screen
    /// is worth repainting. The final update is never lost: the throttle's
    /// final-chunk rule always admits the update that reaches the total.
    private func resolveLocked(trigger: Session) -> Publish {
        let sampledAt = now()
        let transferred = trigger.transferredBytes
        trigger.rate.record(bytes: transferred, seconds: sampledAt)

        let admits: Bool
        if !trigger.revealed {
            guard sampledAt - trigger.startedAt >= revealDelay else { return .none }
            trigger.revealed = true
            // The reveal bypassed the throttle, so its watermarks must still
            // reflect what just went on screen — otherwise the next update would
            // measure its delta from a byte count already shown.
            trigger.coalescer.markForwarded(bytesTransferred: transferred)
            admits = true
        } else {
            admits = trigger.coalescer.shouldForward(
                bytesTransferred: transferred, totalBytes: trigger.totalBytes)
        }

        if let current = trigger.activeUnits.last, let name = trigger.units[current]?.name {
            trigger.lastActiveName = name
        }
        return resolveLocked(admits: admits)
    }

    /// Resolves what to publish for an event whose admission is already decided.
    ///
    /// Caller holds `lock`.
    private func resolveLocked(admits: Bool) -> Publish {
        guard admits else { return .none }
        let projection = projectionLocked()
        guard projection != nil || showing else { return .none }
        showing = projection != nil
        return .emit(projection)
    }

    /// The most-significant revealed session — the one with the most bytes
    /// *remaining* (ties broken by the older session), or `nil` when none is
    /// revealed.
    ///
    /// Ranking by bytes-remaining, not largest-total, keeps a just-finished
    /// operation lingering at 100 % from masking a freshly-started one. Caller
    /// holds `lock`.
    private func projectionLocked() -> ClipboardProgressSnapshot? {
        func remaining(_ session: Session) -> UInt64 {
            let total = session.totalBytes
            let done = min(session.transferredBytes, total)
            return total - done
        }
        let winner = sessions.values.filter(\.revealed)
            .min { lhs, rhs in
                let lhsRemaining = remaining(lhs)
                let rhsRemaining = remaining(rhs)
                if lhsRemaining != rhsRemaining { return lhsRemaining > rhsRemaining }
                return lhs.token.value < rhs.token.value
            }
        guard let session = winner else { return nil }
        let transferred = session.transferredBytes
        let total = session.totalBytes
        return ClipboardProgressSnapshot(
            direction: session.direction,
            peerName: session.peerName,
            currentItemName: session.lastActiveName,
            filesCompleted: session.completedCount,
            fileCount: session.units.count,
            bytesTransferred: min(transferred, total),
            totalBytes: total,
            bytesPerSecond: session.rate.bytesPerSecond,
            secondsRemaining: session.rate.secondsRemaining(bytes: transferred, total: total),
            isPasteSession: session.isPaste,
            elapsedSeconds: max(0, now() - session.startedAt))
    }
}
