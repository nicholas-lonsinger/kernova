import Foundation
import KernovaLogging
import KernovaSynchronization

/// Identity of one ``ClipboardTransferOperation``.
///
/// Carried on every readout, so a surface's Cancel reaches the operation that
/// readout was rendered for and no other — the readout is the only handle the
/// user has on a transfer, and several run at once.
///
/// A minted counter rather than the object's address: an address is reused once
/// the operation it named is gone, and a surface holding the readout it last
/// rendered would then cancel a stranger.
public struct ClipboardTransferOperationID: Hashable, Sendable {
    private static let lastMinted = Locked<UInt64>(0)

    private let value: UInt64

    private init(value: UInt64) { self.value = value }

    /// Mints an identity nothing else holds. The counter starts above
    /// ``unattached``, so a minted identity never collides with it.
    public init() {
        value = Self.lastMinted.withLock {
            $0 &+= 1
            return $0
        }
    }

    /// The identity of a readout no operation produced — a snapshot a test or a
    /// preview built by hand. Cancelling it reaches nothing, which is the point:
    /// there is nothing behind it to stop.
    public static let unattached = ClipboardTransferOperationID(value: 0)
}

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
/// Lock-based rather than `@MainActor`: stream lanes drive it from any thread.
public final class ClipboardTransferOperation: Sendable {
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

    /// What an event left for `deliver` to run once the lock is released.
    ///
    /// Deferred because an `os_log` under the lock would put every chunk
    /// callback behind it.
    private struct Outcome {
        var call: ReporterCall?
        var logs: [LogEvent] = []
    }

    /// One publication to the reporter, resolved under the lock.
    private enum ReporterCall: Sendable {
        case running(ClipboardProgressSnapshot, since: Date)
        case queued
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

    /// What every readout of this operation names it by.
    private struct Header: Sendable {
        let id: ClipboardTransferOperationID
        let gesture: ClipboardTransferGesture
        let direction: ClipboardProgressSnapshot.Direction
        let peerName: String
        let isCancellable: Bool
        /// When the operation began, in wall-clock terms, so an app-level
        /// surface can rank concurrent operations across VMs.
        let startedDate: Date
    }

    private let header: Header

    /// What a surface cancels this operation by.
    public var id: ClipboardTransferOperationID { header.id }

    // MARK: - Injected seams

    private let revealDelay: TimeInterval
    private let idleGap: TimeInterval
    /// What the reveal gate, the readout's timings and the idle terminal are
    /// measured on.
    private let clock: any EngineClock
    /// Stops what this operation measures, when it can be cancelled at all. `nil`
    /// is what leaves the readout without a Cancel button.
    private let onCancelRequested: (@Sendable () -> Void)?
    private let reporter: ClipboardTransferReporter

    // MARK: - Locked state

    /// What the readout is built from; every event changes it in one `withLock`.
    private struct State: Sendable {
        let startedAt: EngineInstant
        /// Floor for the denominator — what the whole operation advertised before
        /// any transfer began. Units revise the figure upward, never below this.
        let expectedBytes: UInt64
        /// Floor for the file count, so a drop's bar counts every dropped file
        /// rather than each in turn.
        let expectedItems: Int
        private(set) var units: [UInt64: UnitState] = [:]
        /// Bytes moved across the whole operation.
        ///
        /// A running sum rather than a reduction over `units` on demand: both
        /// totals are read on *every* event, and a folder paste holds one unit per
        /// file, so reducing would scale the hot path with the tree's size.
        private(set) var transferredBytes: UInt64 = 0
        /// Bytes the units expect to move; see `transferredBytes`.
        private(set) var declaredBytes: UInt64 = 0
        var completedCount = 0
        /// The first failure a transfer reported for itself, which a terminal
        /// that would complete reports instead.
        var unitFailure: ClipboardTransferFailure?
        /// Transfers currently in flight, in the order they began; the readout
        /// names the most recently begun one.
        var activeUnits: [UInt64] = []
        /// Last file seen streaming, kept so the readout still names something
        /// during the gap between two transfers.
        var lastActiveName: String?
        /// Whether the reveal gate has been passed — once true, the readout is on
        /// screen and the terminal must clear it.
        var revealed = false
        /// Whether anything has been published, so a terminal inside the reveal
        /// gate knows it has nothing to retire.
        var published = false
        var isFinished = false
        /// The armed idle terminal, `nil` while none is.
        ///
        /// A transfer beginning, or any terminal, cancels it under the lock, and
        /// the terminal acts only if it takes the lock uncancelled — so one armed
        /// before a transfer began can never complete the operation.
        var idleTerminal: Task<Void, Never>?
        /// This operation's share of the republish-rate bound — the aggregate is
        /// a single byte stream even when several transfers feed it.
        var coalescer = FetchProgressCoalescer()
        var rate = TransferRateEstimator()

        init(startedAt: EngineInstant, expectedBytes: UInt64, expectedItems: Int) {
            self.startedAt = startedAt
            self.expectedBytes = expectedBytes
            self.expectedItems = expectedItems
        }

        /// The denominator: what the units declare, never below what the
        /// operation advertised up front.
        var totalBytes: UInt64 { max(declaredBytes, expectedBytes) }

        /// Installs one transfer's state, keeping the running sums in step.
        mutating func setUnit(_ id: UInt64, _ state: UnitState) {
            let previous = units[id]
            declaredBytes = declaredBytes &- (previous?.expected ?? 0) &+ state.expected
            transferredBytes = transferredBytes &- (previous?.observed ?? 0) &+ state.observed
            units[id] = state
        }

        /// Calls off the armed idle terminal.
        mutating func cancelIdleTerminal() {
            idleTerminal?.cancel()
            idleTerminal = nil
        }

        /// Decides whether this event, sampled at `now`, may reach the UI, then
        /// resolves what to publish.
        ///
        /// Only the reveal bypasses the throttle; everything else — the per-file
        /// counter included — rides the coalescer, since a folder can complete
        /// thousands of small files faster than a screen is worth repainting. The
        /// final update is never lost: the throttle's final-chunk rule always
        /// admits the update that reaches the total.
        mutating func resolve(at now: EngineInstant, revealDelay: TimeInterval, header: Header) -> Outcome {
            let elapsed = startedAt.seconds(to: now)
            rate.record(bytes: transferredBytes, seconds: elapsed)

            var logs: [LogEvent] = []
            let admits: Bool
            if !revealed {
                guard elapsed >= revealDelay else { return Outcome() }
                revealed = true
                // The reveal bypassed the throttle, so its watermarks must still
                // reflect what just went on screen — otherwise the next update
                // would measure its delta from a byte count already shown.
                coalescer.markForwarded(bytesTransferred: transferredBytes, at: now)
                logs.append(.revealed(elapsed: elapsed, transferred: transferredBytes, total: totalBytes))
                admits = true
            } else {
                admits = coalescer.shouldForward(
                    bytesTransferred: transferredBytes, totalBytes: totalBytes, at: now)
            }
            if let current = activeUnits.last, let name = units[current]?.name {
                lastActiveName = name
            }
            guard admits else { return Outcome(logs: logs) }
            published = true
            let snapshot = snapshot(at: now, header: header)
            logs.append(.emission(snapshot))
            return Outcome(call: .running(snapshot, since: header.startedDate), logs: logs)
        }

        /// Resolves a terminal reached at `now`.
        mutating func finish(_ terminal: Terminal, at now: EngineInstant, header: Header) -> Outcome {
            guard !isFinished else { return Outcome() }
            isFinished = true
            cancelIdleTerminal()
            let outcome: ClipboardTransferOutcome
            let label: String
            var isFailure = false
            switch terminal {
            case .completed:
                if let unitFailure {
                    outcome = .failed(unitFailure)
                    label = "failed"
                    isFailure = true
                } else {
                    outcome = .completed(final: snapshot(at: now, header: header))
                    label = "completed"
                }
            case .cancelled:
                outcome = .cancelled(final: snapshot(at: now, header: header))
                label = "cancelled"
            case .failed(let failure):
                outcome = .failed(failure)
                label = "failed"
                isFailure = true
            }
            let logs: [LogEvent] = [ended(label, at: now)]
            // A refusal is owed an answer whether or not a bar ever appeared; a
            // completion nobody saw has nothing to say.
            guard revealed || isFailure else {
                return published ? Outcome(call: .retire, logs: logs) : Outcome(logs: logs)
            }
            published = true
            let finish = ClipboardTransferFinish(
                gesture: header.gesture, outcome: outcome, peerName: header.peerName, date: Date())
            return Outcome(call: .finished(finish), logs: logs)
        }

        /// Ends the operation without a finished report.
        mutating func abandon(at now: EngineInstant) -> Outcome {
            guard !isFinished else { return Outcome() }
            isFinished = true
            cancelIdleTerminal()
            let logs: [LogEvent] = [ended("abandoned", at: now)]
            guard published else { return Outcome(logs: logs) }
            return Outcome(call: .retire, logs: logs)
        }

        func snapshot(at now: EngineInstant, header: Header) -> ClipboardProgressSnapshot {
            let total = totalBytes
            return ClipboardProgressSnapshot(
                direction: header.direction,
                peerName: header.peerName,
                currentItemName: lastActiveName,
                filesCompleted: completedCount,
                fileCount: max(units.count, expectedItems),
                bytesTransferred: min(transferredBytes, total),
                totalBytes: total,
                bytesPerSecond: rate.bytesPerSecond,
                secondsRemaining: rate.secondsRemaining(bytes: transferredBytes, total: total),
                gesture: header.gesture,
                elapsedSeconds: max(0, startedAt.seconds(to: now)),
                isCancellable: header.isCancellable,
                operationID: header.id)
        }

        func ended(_ terminal: String, at now: EngineInstant) -> LogEvent {
            .ended(
                terminal: terminal, elapsed: max(0, startedAt.seconds(to: now)),
                transferred: transferredBytes, total: totalBytes, revealed: revealed)
        }
    }

    private let state: Locked<State>

    // MARK: - Init

    /// Starts measuring one operation, publishing to `reporter`.
    ///
    /// `expectedBytes`/`expectedItems` are a **floor** for the denominator, for
    /// an operation that knows its whole set up front (a drop); units revise it
    /// upward as they are declared.
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
        clock: any EngineClock = makePlatformEngineClock(),
        onCancelRequested: (@Sendable () -> Void)? = nil,
        reporter: ClipboardTransferReporter
    ) {
        self.header = Header(
            id: ClipboardTransferOperationID(), gesture: gesture, direction: direction,
            peerName: peerName, isCancellable: onCancelRequested != nil, startedDate: Date())
        self.revealDelay = revealDelay
        self.idleGap = idleGap
        self.clock = clock
        self.onCancelRequested = onCancelRequested
        self.reporter = reporter
        self.state = Locked(
            State(startedAt: clock.now, expectedBytes: expectedBytes, expectedItems: expectedItems))
    }

    /// Retires a readout its owner let go of without a terminal.
    ///
    /// The reporter holds the operation weakly, so without this the last bar
    /// an unended operation published would stand on every surface for good.
    /// Every earlier publication captured `self`, so all of them have landed
    /// before this runs and the retire is the last word.
    deinit {
        let outcome = state.withLock { $0.abandon(at: clock.now) }
        guard outcome.call != nil else { return }
        let reporter = reporter
        let id = header.id
        DispatchQueue.main.async {
            MainActor.assumeIsolated { reporter.retire(id) }
        }
    }

    // MARK: - Transfer events

    /// Announces the operation as accepted but not yet moving bytes, so the
    /// reporter counts it behind whatever readout is on screen.
    ///
    /// The gesture is already done from the user's side — the files are dropped,
    /// the peer has the offer — and only the peer decides when to pull, which it
    /// does one job at a time. Without this the operation is invisible until its
    /// first byte, and a batch waiting its turn looks like a batch that never
    /// happened. It never becomes the readout itself: nothing has begun, so a bar
    /// for it would be a frozen one.
    public func markQueued() {
        deliver(
            state.withLock { state -> Outcome in
                guard !state.isFinished, !state.published else { return Outcome() }
                // Counts as a publication, so a terminal that never reveals
                // still retires the entry this leaves behind.
                state.published = true
                return Outcome(call: .queued)
            })
    }

    /// Records that one of this operation's transfers started, declaring it if
    /// this is the first the operation has heard of it.
    public func unitBegan(id: UInt64, expectedBytes: UInt64 = 0, name: String? = nil) {
        apply(id: id, declaring: UnitState(expected: expectedBytes, name: name)) { state, unit in
            if !state.activeUnits.contains(unit) { state.activeUnits.append(unit) }
            state.lastActiveName = state.units[unit]?.name ?? state.lastActiveName
            // A transfer in flight means the operation isn't idle: call off the
            // terminal armed for the gap this transfer just filled.
            state.cancelIdleTerminal()
        }
    }

    /// Records one transfer's cumulative byte count.
    ///
    /// `totalBytes` is **wire-authoritative**: a non-zero value replaces whatever
    /// the operation advertised, because the advertised figure can be an estimate
    /// while the stream carries something else entirely — a directory rep
    /// advertises a stat-walk size and then streams a compressed archive.
    public func unitProgressed(id: UInt64, bytesTransferred: UInt64, totalBytes: UInt64 = 0) {
        apply(id: id, declaring: nil) { state, unit in
            guard var unitState = state.units[unit] else { return }
            if totalBytes > 0 { unitState.expected = totalBytes }
            unitState.observed = max(unitState.observed, min(bytesTransferred, unitState.expected))
            state.setUnit(unit, unitState)
            // Does NOT touch `activeUnits`: a chunk callback fires on the
            // transfer's own lane, so one can land *after* the transfer
            // finished, and re-adding the unit here would leave the operation
            // permanently "active" — the idle terminal would never fire and the
            // readout would stick on screen forever.
        }
    }

    /// Records one transfer's terminal, crediting a successful one in full.
    public func unitEnded(id: UInt64, succeeded: Bool) {
        apply(id: id, declaring: nil) { state, unit in
            state.activeUnits.removeAll { $0 == unit }
            guard succeeded, var unitState = state.units[unit] else { return }
            if !unitState.completed {
                unitState.completed = true
                state.completedCount += 1
            }
            // Credit the expected byte count in full: the throttle can have
            // suppressed the final chunks, and a completed transfer must read as
            // complete.
            unitState.observed = unitState.expected
            state.setUnit(unit, unitState)
        }
    }

    /// Records why one of this operation's transfers failed, for a transfer
    /// that knows: a terminal that would complete the operation — its idle
    /// gap's, or its owner's — ends it failed with the first such failure, since
    /// what it measured did not all arrive.
    ///
    /// The transfer still ends through ``unitEnded(id:succeeded:)``.
    public func unitFailed(id: UInt64, _ failure: ClipboardTransferFailure) {
        apply(id: id, declaring: nil) { state, _ in
            if state.unitFailure == nil { state.unitFailure = failure }
        }
    }

    // MARK: - Terminals

    /// Ends the operation, publishing its finished report.
    ///
    /// For a caller that owns the loop — a preview fetch, a paste fire, a drop.
    /// Idempotent; later events are dropped. `.completed` reports a failure
    /// ``unitFailed(id:_:)`` recorded instead. A `.completed`/`.cancelled` terminal
    /// inside the reveal gate publishes nothing, so an operation nobody saw never
    /// flashes UI; a `.failed` one always reports, since a refusal is owed an
    /// answer whether or not a bar was on screen.
    public func finish(_ terminal: Terminal) {
        deliver(state.withLock { $0.finish(terminal, at: clock.now, header: header) })
    }

    /// Arms the idle terminal: the operation completes `idleGap` after its last
    /// transfer ends if nothing has begun since, and its owner still holds it —
    /// one let go of first retires its readout instead.
    ///
    /// For a peer-driven operation, where nothing on this side knows the peer has
    /// stopped asking. Nothing in flight is not "finished" — a multi-file paste is
    /// walked one file at a time, so the gap between two of them looks exactly
    /// like the end, and this gap is what tells them apart.
    public func finishWhenIdle() {
        state.withLock { state in
            guard !state.isFinished, state.activeUnits.isEmpty, state.idleTerminal == nil else { return }
            state.idleTerminal = clock.schedule(after: idleGap) { [weak self] in
                self?.idleTerminalFired()
            }
        }
    }

    /// Retires the operation without a finished report — a teardown, where what
    /// the readout was measuring no longer exists.
    public func abandon() {
        deliver(state.withLock { $0.abandon(at: clock.now) })
    }

    /// Whether this operation can still take events.
    ///
    /// A caller that *caches* an operation across events must ask before reusing
    /// one: events after a terminal are dropped, and a reused finished operation
    /// silently measures nothing at all.
    public var isLive: Bool { state.withLock { !$0.isFinished } }

    /// Whether this operation can be stopped, which is what puts a Cancel
    /// affordance on its readout.
    public var isCancellable: Bool { header.isCancellable }

    /// Stops what this operation measures, if it can be stopped at all.
    public func requestCancel() {
        guard let onCancelRequested else { return }
        Self.logger.log(
            .notice,
            "Cancel requested for a \(String(describing: self.header.gesture), privacy: .public) transfer")
        onCancelRequested()
    }

    // MARK: - Event plumbing

    /// Shared event path.
    ///
    /// `declaring` is non-nil only for `unitBegan`, the one event allowed to
    /// introduce a transfer. Progress and terminals for an unknown transfer are
    /// dropped: a chunk landing after the operation ended must never mint a new
    /// unit, since nothing would arm a terminal for it.
    private func apply(
        id: UInt64, declaring declared: UnitState?, _ mutate: (inout State, UInt64) -> Void
    ) {
        deliver(
            state.withLock { state -> Outcome in
                guard !state.isFinished else { return Outcome() }
                if state.units[id] == nil {
                    guard let declared else { return Outcome() }
                    state.setUnit(id, declared)
                }
                mutate(&state, id)
                return state.resolve(at: clock.now, revealDelay: revealDelay, header: header)
            })
    }

    /// Completes the operation once it has stayed idle for the whole gap.
    ///
    /// Runs on the idle terminal's own task, so a cancel that landed first is
    /// what `Task.isCancelled` reads under the lock.
    private func idleTerminalFired() {
        deliver(
            state.withLock { state -> Outcome in
                guard !Task.isCancelled else { return Outcome() }
                return state.finish(.completed, at: clock.now, header: header)
            })
    }

    /// Runs an event's deferred work — the records and the publication — with
    /// the lock released.
    private func deliver(_ outcome: Outcome) {
        for event in outcome.logs { log(event) }
        if let call = outcome.call { send(call) }
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
                case .queued:
                    reporter.queued(self)
                case .finished(let finish):
                    reporter.publish(from: self, .finished(finish))
                case .retire:
                    reporter.retire(self)
                }
            }
        }
    }

    // MARK: - Records

    private func log(_ event: LogEvent) {
        switch event {
        case .revealed(let elapsed, let transferred, let total):
            Self.logger.log(
                .info,
                "\(String(describing: self.header.gesture), privacy: .public) \(String(describing: self.header.direction), privacy: .public) '\(self.header.peerName, privacy: .public)' revealed at \(ClipboardProgressFormat.logSeconds(elapsed), privacy: .public) — \(transferred, privacy: .public)/\(total, privacy: .public) bytes"
            )
        case .ended(let terminal, let elapsed, let transferred, let total, let revealed):
            Self.logger.log(
                .info,
                "\(String(describing: self.header.gesture), privacy: .public) \(String(describing: self.header.direction), privacy: .public) '\(self.header.peerName, privacy: .public)' \(terminal, privacy: .public) after \(ClipboardProgressFormat.logSeconds(elapsed), privacy: .public) — \(transferred, privacy: .public)/\(total, privacy: .public) bytes, revealed=\(revealed, privacy: .public)"
            )
        case .emission(let snapshot):
            Self.logger.log(
                .debug,
                "\(String(describing: self.header.gesture), privacy: .public) readout — \(snapshot.bytesTransferred, privacy: .public)/\(snapshot.totalBytes, privacy: .public) bytes, \(ClipboardProgressFormat.logSeconds(snapshot.elapsedSeconds), privacy: .public) elapsed, \(ClipboardProgressFormat.logSeconds(snapshot.secondsRemaining), privacy: .public) remaining"
            )
        }
    }
}
