import Foundation

/// One user-visible clipboard operation, aggregating every transfer it makes
/// into the single readout each progress surface renders.
///
/// **One operation per object; the object is the identity** — a preview fetch, a
/// paste, one side serving a peer's pulls, a drop. Its bar climbs once whether
/// its transfers run sequentially or concurrently, it shows nothing until it has
/// been running for `revealDelay` (evaluated on each event, so an operation that
/// finishes inside the gate never flashes UI), and it publishes exactly one
/// terminal to its ``ClipboardTransferReporter``.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`. It must
/// stay lock-based rather than `@MainActor` — the guest agent drives it from
/// main-queue-confined (but non-`@MainActor`) callbacks, and stream lanes drive
/// it from any thread.
public final class ClipboardTransferOperation: @unchecked Sendable {
    /// How long an operation must have been running before its progress shows.
    ///
    /// Uniform across every passive surface; the status-item dropdown, which
    /// interrupts by opening itself, carries its own much stricter gate in
    /// `ClipboardProgressMenuAutoOpener`.
    public static let defaultRevealDelay: TimeInterval = 0.3

    /// How long a peer-driven operation may sit with nothing in flight before
    /// ``finishWhenIdle()`` calls it over.
    public static let defaultIdleGap: TimeInterval = 2.0

    /// How an operation ended.
    public enum Terminal: Sendable {
        case completed
        case cancelled
        case failed(ClipboardTransferFailure)
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

    /// What an event left for `deliver` to run once `lock` is released.
    ///
    /// `emit`-side work is deferred because the reporter hop and the scheduler
    /// are injected closures a caller may run synchronously, and an `os_log`
    /// under the lock would put every chunk callback behind it.
    private struct Outcome {
        var call: ReporterCall?
        var armIdle: UInt64?
        var logs: [LogEvent] = []
    }

    /// One publication to the reporter, resolved under `lock`.
    private enum ReporterCall: Sendable {
        case running(ClipboardProgressSnapshot, since: Date)
        case finished(ClipboardTransferFinish)
        case retire
    }

    private enum LogEvent: Sendable {
        case revealed(elapsed: TimeInterval, transferred: UInt64, total: UInt64)
        case ended(
            terminal: String, elapsed: TimeInterval, transferred: UInt64, total: UInt64,
            revealed: Bool)
        case emission(ClipboardProgressSnapshot)
    }

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardTransfer")

    // MARK: - Identity

    private let gesture: ClipboardTransferGesture
    private let direction: ClipboardProgressSnapshot.Direction
    private let peerName: String
    /// When the operation began, in wall-clock terms, so an app-level surface can
    /// rank concurrent operations across VMs.
    private let startedDate = Date()

    // MARK: - Injected seams

    private let revealDelay: TimeInterval
    private let idleGap: TimeInterval
    /// Monotonic seconds.
    private let now: @Sendable () -> TimeInterval
    /// Runs `work` after a delay — the idle terminal's only trigger, since by
    /// definition no further transfer event arrives to drive it.
    private let schedule: @Sendable (_ after: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void
    /// Stops what this operation measures, when it can be cancelled at all. `nil`
    /// is what leaves the readout without a Cancel button.
    private let onCancelRequested: (@Sendable () -> Void)?
    private let reporter: ClipboardTransferReporter

    // MARK: - Locked state

    private let lock = NSLock()
    private let startedAt: TimeInterval
    private var units: [UInt64: UnitState] = [:]
    /// Bytes moved across the whole operation.
    ///
    /// A running sum rather than a reduction over `units` on demand: both totals
    /// are read on *every* event, and a folder paste holds one unit per file, so
    /// reducing would scale the hot path with the tree's size.
    private var transferredBytes: UInt64 = 0
    /// Bytes the units expect to move; see `transferredBytes`.
    private var declaredBytes: UInt64 = 0
    /// Floor for the denominator — what the whole operation advertised before any
    /// transfer began. Units revise the figure upward, never below this.
    private let expectedBytes: UInt64
    /// Floor for the file count, so a drop's bar counts every dropped file rather
    /// than each in turn.
    private let expectedItems: Int
    private var completedCount = 0
    /// Transfers currently in flight, in the order they began; the readout names
    /// the most recently begun one.
    private var activeUnits: [UInt64] = []
    /// Last file seen streaming, kept so the readout still names something during
    /// the gap between two transfers.
    private var lastActiveName: String?
    /// Whether the reveal gate has been passed — once true, the readout is on
    /// screen and the terminal must clear it.
    private var revealed = false
    /// Whether anything has been published, so a terminal inside the reveal gate
    /// knows it has nothing to retire.
    private var published = false
    private var isFinished = false
    /// Bumped whenever a transfer begins, so an already-scheduled idle terminal
    /// can tell it was superseded.
    private var idleEpoch: UInt64 = 0
    /// This operation's share of the republish-rate bound — the aggregate is a
    /// single byte stream even when several transfers feed it.
    private let coalescer = FetchProgressCoalescer()
    private var rate = TransferRateEstimator()

    // MARK: - Init

    /// Starts measuring one operation, publishing to `reporter`.
    ///
    /// `expectedBytes`/`expectedItems` are a **floor** for the denominator, for
    /// an operation that knows its whole set up front (a drop); units revise it
    /// upward as they are declared. `now` and `schedule` default to the system
    /// monotonic clock and the main queue; tests inject their own so no wait is
    /// timing-based.
    ///
    /// `onCancelRequested` stops what this operation measures — the transfers,
    /// not the offer behind them — and is what puts a Cancel affordance on the
    /// readout. It is invoked outside the lock, may fire more than once, and may
    /// fire after the operation has ended, so it must be idempotent.
    public init(
        gesture: ClipboardTransferGesture,
        direction: ClipboardProgressSnapshot.Direction,
        peerName: String,
        expectedBytes: UInt64 = 0,
        expectedItems: Int = 0,
        revealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        idleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        now: @escaping @Sendable () -> TimeInterval = {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        },
        schedule: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = {
            after, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
        },
        onCancelRequested: (@Sendable () -> Void)? = nil,
        reporter: ClipboardTransferReporter
    ) {
        self.gesture = gesture
        self.direction = direction
        self.peerName = peerName
        self.expectedBytes = expectedBytes
        self.expectedItems = expectedItems
        self.revealDelay = revealDelay
        self.idleGap = idleGap
        self.now = now
        self.schedule = schedule
        self.onCancelRequested = onCancelRequested
        self.reporter = reporter
        self.startedAt = now()
    }

    // MARK: - Transfer events

    /// Records that one of this operation's transfers started, declaring it if
    /// this is the first the operation has heard of it.
    public func unitBegan(id: UInt64, expectedBytes: UInt64 = 0, name: String? = nil) {
        apply(id: id, declaring: UnitState(expected: expectedBytes, name: name)) { unit in
            if !self.activeUnits.contains(unit) { self.activeUnits.append(unit) }
            self.lastActiveName = self.units[unit]?.name ?? self.lastActiveName
            // A transfer in flight means the operation isn't idle: invalidate the
            // terminal scheduled for the gap this transfer just filled.
            self.idleEpoch &+= 1
        }
    }

    /// Records one transfer's cumulative byte count.
    ///
    /// `totalBytes` is **wire-authoritative**: a non-zero value replaces whatever
    /// the operation advertised, because the advertised figure can be an estimate
    /// while the stream carries something else entirely — a directory rep
    /// advertises a stat-walk size and then streams a compressed archive.
    public func unitProgressed(id: UInt64, bytesTransferred: UInt64, totalBytes: UInt64 = 0) {
        apply(id: id, declaring: nil) { unit in
            guard var state = self.units[unit] else { return }
            if totalBytes > 0 { state.expected = totalBytes }
            state.observed = max(state.observed, min(bytesTransferred, state.expected))
            self.setUnit(unit, state)
            // Deliberately does NOT touch `activeUnits`: a chunk callback fires on
            // the transfer's own lane, so one can land *after* the transfer
            // finished, and re-adding the unit here would leave the operation
            // permanently "active" — the idle terminal would never fire and the
            // readout would stick on screen forever.
        }
    }

    /// Records one transfer's terminal, crediting a successful one in full.
    public func unitEnded(id: UInt64, succeeded: Bool) {
        apply(id: id, declaring: nil) { unit in
            self.activeUnits.removeAll { $0 == unit }
            guard succeeded, var state = self.units[unit] else { return }
            if !state.completed {
                state.completed = true
                self.completedCount += 1
            }
            // Credit the expected byte count in full: the throttle can have
            // suppressed the final chunks, and a completed transfer must read as
            // complete.
            state.observed = state.expected
            self.setUnit(unit, state)
        }
    }

    // MARK: - Terminals

    /// Ends the operation, publishing its finished report.
    ///
    /// For a caller that owns the loop — a preview fetch, a paste fire, a drop.
    /// Idempotent; later events are dropped. A `.completed`/`.cancelled` terminal
    /// inside the reveal gate publishes nothing, so an operation nobody saw never
    /// flashes UI; a `.failed` one always reports, since a refusal is owed an
    /// answer whether or not a bar was on screen.
    public func finish(_ terminal: Terminal) {
        deliver(lock.withLock { finishLocked(terminal) })
    }

    /// Arms the idle terminal: the operation completes `idleGap` after its last
    /// transfer ends if nothing has begun since.
    ///
    /// For a peer-driven operation, where nothing on this side knows the peer has
    /// stopped asking. Nothing in flight is not "finished" — a multi-file paste is
    /// walked one file at a time, so the gap between two of them looks exactly
    /// like the end, and this gap is what tells them apart.
    public func finishWhenIdle() {
        deliver(
            lock.withLock { () -> Outcome in
                guard !isFinished, activeUnits.isEmpty else { return Outcome() }
                return Outcome(armIdle: idleEpoch)
            })
    }

    /// Retires the operation without a finished report — a teardown, where what
    /// the readout was measuring no longer exists.
    public func abandon() {
        deliver(
            lock.withLock { () -> Outcome in
                guard !isFinished else { return Outcome() }
                isFinished = true
                let logs: [LogEvent] = [endedLocked("abandoned")]
                guard published else { return Outcome(logs: logs) }
                return Outcome(call: .retire, logs: logs)
            })
    }

    /// Whether this operation can still take events.
    ///
    /// A caller that *caches* an operation across events must ask before reusing
    /// one: events after a terminal are dropped, and a reused finished operation
    /// silently measures nothing at all.
    public var isLive: Bool { lock.withLock { !isFinished } }

    /// Whether this operation can be stopped, which is what puts a Cancel
    /// affordance on its readout.
    public var isCancellable: Bool { onCancelRequested != nil }

    /// Stops what this operation measures, if it can be stopped at all.
    public func requestCancel() {
        guard let onCancelRequested else { return }
        Self.logger.notice("Cancel requested for a \(self.gesture, privacy: .public) transfer")
        onCancelRequested()
    }

    // MARK: - Event plumbing

    /// Shared event path.
    ///
    /// `declaring` is non-nil only for `unitBegan`, the one event allowed to
    /// introduce a transfer. Progress and terminals for an unknown transfer are
    /// dropped: a chunk landing after the operation ended must never mint a new
    /// unit, since nothing would arm a terminal for it.
    private func apply(id: UInt64, declaring declared: UnitState?, _ mutate: (UInt64) -> Void) {
        deliver(
            lock.withLock { () -> Outcome in
                guard !isFinished else { return Outcome() }
                if units[id] == nil {
                    guard let declared else { return Outcome() }
                    setUnit(id, declared)
                }
                mutate(id)
                return resolveLocked()
            })
    }

    /// Installs one transfer's state, keeping the running sums in step.
    ///
    /// Caller holds `lock`.
    private func setUnit(_ id: UInt64, _ state: UnitState) {
        let previous = units[id]
        declaredBytes = declaredBytes &- (previous?.expected ?? 0) &+ state.expected
        transferredBytes = transferredBytes &- (previous?.observed ?? 0) &+ state.observed
        units[id] = state
    }

    /// Decides whether this event may reach the UI, then resolves what to publish.
    ///
    /// Caller holds `lock`. Only the reveal bypasses the throttle; everything
    /// else — the per-file counter included — rides the coalescer, since a folder
    /// can complete thousands of small files faster than a screen is worth
    /// repainting. The final update is never lost: the throttle's final-chunk rule
    /// always admits the update that reaches the total.
    private func resolveLocked() -> Outcome {
        let sampledAt = now()
        rate.record(bytes: transferredBytes, seconds: sampledAt)

        var logs: [LogEvent] = []
        let admits: Bool
        if !revealed {
            guard sampledAt - startedAt >= revealDelay else { return Outcome() }
            revealed = true
            // The reveal bypassed the throttle, so its watermarks must still
            // reflect what just went on screen — otherwise the next update would
            // measure its delta from a byte count already shown.
            coalescer.markForwarded(bytesTransferred: transferredBytes)
            logs.append(
                .revealed(
                    elapsed: sampledAt - startedAt, transferred: transferredBytes,
                    total: totalBytesLocked))
            admits = true
        } else {
            admits = coalescer.shouldForward(
                bytesTransferred: transferredBytes, totalBytes: totalBytesLocked)
        }
        if let current = activeUnits.last, let name = units[current]?.name {
            lastActiveName = name
        }
        guard admits else { return Outcome(logs: logs) }
        published = true
        let snapshot = snapshotLocked()
        logs.append(.emission(snapshot))
        return Outcome(call: .running(snapshot, since: startedDate), logs: logs)
    }

    /// Resolves a terminal under `lock`.
    private func finishLocked(_ terminal: Terminal) -> Outcome {
        guard !isFinished else { return Outcome() }
        isFinished = true
        let outcome: ClipboardTransferOutcome
        let label: String
        var isFailure = false
        switch terminal {
        case .completed:
            outcome = .completed(final: snapshotLocked())
            label = "completed"
        case .cancelled:
            outcome = .cancelled(final: snapshotLocked())
            label = "cancelled"
        case .failed(let failure):
            outcome = .failed(failure)
            label = "failed"
            isFailure = true
        }
        let logs: [LogEvent] = [endedLocked(label)]
        // A refusal is owed an answer whether or not a bar ever appeared; a
        // completion nobody saw has nothing to say.
        guard revealed || isFailure else {
            return published ? Outcome(call: .retire, logs: logs) : Outcome(logs: logs)
        }
        published = true
        let finish = ClipboardTransferFinish(
            gesture: gesture, outcome: outcome, peerName: peerName, date: Date())
        return Outcome(call: .finished(finish), logs: logs)
    }

    /// Completes the operation once it has stayed idle for the whole gap.
    private func idleTerminalFired(epoch: UInt64) {
        deliver(
            lock.withLock { () -> Outcome in
                guard !isFinished, idleEpoch == epoch, activeUnits.isEmpty else { return Outcome() }
                return finishLocked(.completed)
            })
    }

    /// Runs an event's deferred work — the records, the publication and the idle
    /// arming — with `lock` released.
    private func deliver(_ outcome: Outcome) {
        for event in outcome.logs { log(event) }
        if let call = outcome.call { send(call) }
        guard let epoch = outcome.armIdle else { return }
        schedule(idleGap) { [weak self] in self?.idleTerminalFired(epoch: epoch) }
    }

    /// Publishes to the reporter through one serial main hop, so a snapshot can
    /// never overtake the one before it.
    ///
    /// A `Task { @MainActor }` per emission would not: two independently
    /// scheduled hops carrying immutable snapshots have no ordering guarantee,
    /// and the bar would jump backwards. Emissions are already rate-bounded by
    /// the coalescer, so the hop count is too.
    private func send(_ call: ReporterCall) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                switch call {
                case .running(let snapshot, let since):
                    reporter.publish(from: self, .running(snapshot, since: since))
                case .finished(let finish):
                    reporter.publish(from: self, .finished(finish))
                case .retire:
                    reporter.retire(self)
                }
            }
        }
    }

    // MARK: - Projection

    /// The denominator: what the units declare, never below what the operation
    /// advertised up front.
    ///
    /// Caller holds `lock`.
    private var totalBytesLocked: UInt64 { max(declaredBytes, expectedBytes) }

    /// Caller holds `lock`.
    private func snapshotLocked() -> ClipboardProgressSnapshot {
        let total = totalBytesLocked
        return ClipboardProgressSnapshot(
            direction: direction,
            peerName: peerName,
            currentItemName: lastActiveName,
            filesCompleted: completedCount,
            fileCount: max(units.count, expectedItems),
            bytesTransferred: min(transferredBytes, total),
            totalBytes: total,
            bytesPerSecond: rate.bytesPerSecond,
            secondsRemaining: rate.secondsRemaining(bytes: transferredBytes, total: total),
            gesture: gesture,
            elapsedSeconds: max(0, now() - startedAt),
            isCancellable: onCancelRequested != nil)
    }

    // MARK: - Records

    /// Caller holds `lock`.
    private func endedLocked(_ terminal: String) -> LogEvent {
        .ended(
            terminal: terminal, elapsed: max(0, now() - startedAt), transferred: transferredBytes,
            total: totalBytesLocked, revealed: revealed)
    }

    private func log(_ event: LogEvent) {
        switch event {
        case .revealed(let elapsed, let transferred, let total):
            Self.logger.info(
                "\(self.gesture, privacy: .public) \(self.direction, privacy: .public) '\(self.peerName, privacy: .public)' revealed at \(ClipboardProgressFormat.logSeconds(elapsed), privacy: .public) — \(transferred, privacy: .public)/\(total, privacy: .public) bytes"
            )
        case .ended(let terminal, let elapsed, let transferred, let total, let revealed):
            Self.logger.info(
                "\(self.gesture, privacy: .public) \(self.direction, privacy: .public) '\(self.peerName, privacy: .public)' \(terminal, privacy: .public) after \(ClipboardProgressFormat.logSeconds(elapsed), privacy: .public) — \(transferred, privacy: .public)/\(total, privacy: .public) bytes, revealed=\(revealed, privacy: .public)"
            )
        case .emission(let snapshot):
            Self.logger.debug(
                "\(self.gesture, privacy: .public) readout — \(snapshot.bytesTransferred, privacy: .public)/\(snapshot.totalBytes, privacy: .public) bytes, \(ClipboardProgressFormat.logSeconds(snapshot.elapsedSeconds), privacy: .public) elapsed, \(ClipboardProgressFormat.logSeconds(snapshot.secondsRemaining), privacy: .public) remaining"
            )
        }
    }
}
