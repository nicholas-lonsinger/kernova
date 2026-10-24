import Foundation
import KernovaLogging

/// One peer's clipboard transfer state, as every surface renders it — the host
/// keeps one per VM, the guest agent one per process.
///
/// Several producers publish here (a VM's clipboard service, its drop service,
/// its passthrough coordinator), and the report is the highest-ranked running
/// operation, else the last one to finish, else nothing. Whatever the readout
/// leaves out is counted on it as ``ClipboardProgressSnapshot/pendingBehind``,
/// so work queued behind the bar is legible rather than absent. A refusal
/// belongs to the *peer*, not to the connection that raised it: a service
/// superseded by a reconnect still reports the failures of the pasteboard
/// promises it published, and they land here.
///
/// **A refusal is never lost behind another operation.** It shows the moment it
/// is recorded, over any running readout, so the surfaces that interrupt fire at
/// once; the running operation's next emission takes the readout back. When that
/// operation then ends, its terminal clears the refusal only where it disproves
/// it: a completion answers the failures that stood before it began, which is
/// what lets a retry clear the line it is retrying, and nothing a gesture the
/// *peer* made ends with — completion, cancellation, or a refusal of its own —
/// clears a refusal this side's user is owed.
///
/// Not `@Observable` — KernovaKit deploys to macOS 12, which has no Observation.
/// It notifies through ``onReportChanged`` instead, and the host mirrors that
/// into an observed property on `VMInstance`.
@MainActor
public final class ClipboardTransferReporter {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardTransfer")

    /// One live operation — either its latest readout, or its place in the queue
    /// while it waits for the peer to start pulling.
    ///
    /// Keyed by the operation's minted identity, which outlives it: an
    /// operation that goes away unended retires its entry by that identity
    /// from its `deinit`. The reference is weak, so the readout never keeps a
    /// producer alive; it is only what a Cancel reaches.
    private struct Live {
        let id: ClipboardTransferOperationID
        weak var operation: ClipboardTransferOperation?
        /// The latest readout, or `nil` for an operation that has only been
        /// announced — nothing has begun, so there is no bar to render.
        var snapshot: ClipboardProgressSnapshot?
        var since: Date
        /// Where this operation falls in the order the live set first published
        /// bars, which is what settles a tie between equal ranks. `0` until it
        /// publishes one.
        var revealOrder: UInt64 = 0
    }

    /// Live operations in the order they first announced themselves.
    private var live: [Live] = []

    /// Hands out ``Live/revealOrder``. Announcement order cannot stand in for
    /// it: a drop joins the live set when it is offered and publishes its first
    /// bar only once the peer starts pulling, which can be long after something
    /// offered later has been running for minutes.
    private var revealCount: UInt64 = 0

    /// The last operation to finish, until something displaces it, the dwell
    /// retires it, or a caller clears it.
    private var lastFinish: ClipboardTransferFinish?

    /// Whether a repeat of ``lastFinish`` should collapse into it rather than be
    /// announced again.
    ///
    /// Cleared as soon as a later gesture announces itself — an operation
    /// joining the live set, or ``gestureBegan()`` from a gesture that opens
    /// none — so the same refusal raised by that gesture is news again.
    /// Announcing is the trigger rather than opening a bar: an operation whose
    /// transfers all end inside the reveal gate publishes no readout at all, and
    /// two gestures that each lost a file would otherwise reach the user as a
    /// single message.
    private var absorbsRepeats = false

    /// Whether ``lastFinish`` is a refusal that has not yet been displaced by a
    /// running readout.
    ///
    /// A refusal has to reach the surfaces that interrupt — the notice popover,
    /// the dropdown line, the window banner — at the moment it is raised, even
    /// while something else is still transferring. The next `.running` publish
    /// clears this and the bar comes back.
    private var failureAwaitsDisplacement = false

    /// The armed retirement of a completed or cancelled ``report``, cancelled by
    /// every change to it — so a dwell only ever retires the report it was
    /// armed for.
    private var dwell: Task<Void, Never>?

    /// How long a completed or cancelled report stays up before the reporter goes
    /// idle.
    ///
    /// The bar reads 100 % (or where a cancel stopped it) for a beat rather than
    /// vanishing at 99 %, and the status-item ring stays up across the gap
    /// between two sequentially-fired pasteboard promises, because the next
    /// fire's operation displaces the dwell.
    public static let dwellSeconds: TimeInterval = 2

    /// What the dwell is measured on.
    nonisolated private let clock: any EngineClock

    /// What every surface renders.
    public private(set) var report: ClipboardTransferReport = .idle

    /// Called on each distinct value of ``report``.
    public var onReportChanged: ((ClipboardTransferReport) -> Void)?

    /// Creates a reporter.
    ///
    /// `nonisolated` so an owner built off the main actor — a test harness, or a
    /// producer's own initializer — can create one; every method on it still
    /// crosses to the main actor.
    public nonisolated init(clock: any EngineClock = makePlatformEngineClock()) {
        self.clock = clock
    }

    // MARK: - Producer entry points

    /// Records what `operation` just published.
    public func publish(from operation: ClipboardTransferOperation, _ update: ClipboardTransferReport) {
        switch update {
        case .running(let snapshot, let since):
            if let index = live.firstIndex(where: { $0.id == operation.id }) {
                // Only the first bar takes an order: re-ordering the live set on
                // every progress tick would hand the readout back and forth
                // between two transfers running side by side.
                if live[index].snapshot == nil {
                    revealCount &+= 1
                    live[index].revealOrder = revealCount
                }
                live[index].snapshot = snapshot
                live[index].since = since
            } else {
                revealCount &+= 1
                live.append(
                    Live(
                        id: operation.id, operation: operation, snapshot: snapshot,
                        since: since, revealOrder: revealCount))
            }
            absorbsRepeats = false
            // The bar takes the readout back from a refusal that has had its
            // moment on screen; it stays standing underneath.
            failureAwaitsDisplacement = false
            recompute()
        case .finished(let finish):
            let since = live.first { $0.id == operation.id }?.since
            remove(operation.id)
            record(finish, startedAt: since)
        case .idle:
            retire(operation)
        }
    }

    /// Records that `operation` has been accepted but has nothing in flight yet.
    ///
    /// It joins the live set without a readout, so it is counted behind whatever
    /// bar is on screen rather than replacing it with a bar at zero.
    public func queued(_ operation: ClipboardTransferOperation) {
        guard !live.contains(where: { $0.id == operation.id }) else { return }
        live.append(
            Live(id: operation.id, operation: operation, snapshot: nil, since: Date()))
        gestureBegan()
        recompute()
    }

    /// Records that a gesture has begun, so a repeat of what the last one
    /// reported is announced again rather than collapsed into it.
    ///
    /// ``queued(_:)`` says this for a gesture that opens an operation. This is
    /// for the one that opens none — a drag whose items all turn out to be
    /// unreadable, one the channel outlived, one whose offer never got away —
    /// where the refusal is the only trace of the gesture there is, and is owed
    /// the message the identical refusal before it got. What stands is left
    /// alone: a report an earlier gesture raised is not this one's to clear.
    public func gestureBegan() {
        absorbsRepeats = false
    }

    /// Records a refusal raised without a transfer behind it — a pre-flight
    /// check, a peer error frame, a gesture that never opened a stream.
    public func finish(_ finish: ClipboardTransferFinish) {
        record(finish, startedAt: nil)
    }

    /// Drops `operation` from the readout without a finished report.
    public func retire(_ operation: ClipboardTransferOperation) {
        retire(operation.id)
    }

    /// Drops the operation `id` names from the readout without a finished
    /// report — what an operation that goes away unended sends.
    func retire(_ id: ClipboardTransferOperationID) {
        remove(id)
        recompute()
    }

    // MARK: - Surface entry points

    /// Drops a finished report, leaving a running one alone.
    ///
    /// The reset a fresh gesture performs: a new offer, or a reconnect, retires
    /// whatever the last one left standing.
    public func clearFinished() {
        guard lastFinish != nil else { return }
        lastFinish = nil
        absorbsRepeats = false
        failureAwaitsDisplacement = false
        recompute()
    }

    /// Stops the operation `id` names, reporting whether one was reached.
    ///
    /// The readout is the only handle the user has on a transfer, so a Cancel on
    /// it must reach *that* operation and no other. The identity comes off the
    /// readout the surface rendered, which is what keeps the click honest while
    /// several operations run at once and the ranking decides which is shown.
    @discardableResult
    public func cancel(_ id: ClipboardTransferOperationID) -> Bool {
        guard let operation = live.first(where: { $0.id == id })?.operation,
            operation.isCancellable
        else { return false }
        operation.requestCancel()
        return true
    }

    // MARK: - Private

    private func remove(_ id: ClipboardTransferOperationID) {
        live.removeAll { $0.id == id }
    }

    /// Installs `finish` as the standing report, absorbing a repeat of the same
    /// news.
    ///
    /// The N pasteboard fires of one refused multi-file paste each report the
    /// same refusal, and one message is what the user is owed. A gesture
    /// announced in between is a later one, so its repeat is announced again.
    ///
    /// `startedAt` is when the finishing operation began, for the finishes that
    /// must not install themselves over a standing refusal — either because they
    /// disprove nothing about it, or because they are not the same user's news.
    private func record(_ finish: ClipboardTransferFinish, startedAt: Date?) {
        if absorbsRepeats, let standing = lastFinish, standing.isSameNews(as: finish) {
            recompute()
            return
        }
        if let standing = lastFinish, standing.failure != nil {
            // A gesture the peer made answers the peer's user, so nothing it ends
            // with disproves what this side's user is owed — including a refusal
            // of its own, which the surfaces that interrupt would not present
            // here anyway.
            let answersTheOtherUser = !finish.gesture.isMadeHere && standing.gesture.isMadeHere
            // Running to the end says nothing about a transfer that failed
            // alongside; a refusal older than the operation is one the operation
            // retried, so that one is cleared.
            let raisedDuringTheOperation =
                finish.failure == nil && (startedAt.map { standing.date >= $0 } ?? false)
            if answersTheOtherUser || raisedDuringTheOperation {
                recompute()
                return
            }
        }
        lastFinish = finish
        absorbsRepeats = true
        failureAwaitsDisplacement = finish.failure != nil
        if let failure = finish.failure, finish.gesture.isMadeHere {
            Self.logger.log(
                .notice,
                "\(String(describing: finish.gesture), privacy: .public) from '\(finish.peerName, privacy: .public)' failed: \(String(describing: failure), privacy: .public)"
            )
        }
        recompute()
    }

    /// The one running readout every surface shows.
    ///
    /// Ranked by ``ClipboardTransferGesture/readoutRank`` rather than by which
    /// published last, so work started under a gesture someone is waiting on
    /// never takes the bar off it; equal ranks fall back to the last to open a
    /// bar.
    private func shownReadout() -> (snapshot: ClipboardProgressSnapshot, since: Date)? {
        typealias Candidate = (
            rank: Int, revealOrder: UInt64, snapshot: ClipboardProgressSnapshot, since: Date
        )
        let candidates: [Candidate] = live.compactMap { entry in
            guard let snapshot = entry.snapshot else { return nil }
            return (snapshot.gesture.readoutRank, entry.revealOrder, snapshot, entry.since)
        }
        guard let best = candidates.max(by: { ($0.rank, $0.revealOrder) < ($1.rank, $1.revealOrder) })
        else { return nil }
        return (best.snapshot, best.since)
    }

    /// Rebuilds ``report`` and notifies when it changed.
    private func recompute() {
        let next: ClipboardTransferReport
        if failureAwaitsDisplacement, let lastFinish {
            next = .finished(lastFinish)
        } else if let shown = shownReadout() {
            next = .running(shown.snapshot.withPendingBehind(live.count - 1), since: shown.since)
        } else if let lastFinish {
            next = .finished(lastFinish)
        } else {
            next = .idle
        }
        guard next != report else { return }
        dwell?.cancel()
        dwell = nil
        report = next
        onReportChanged?(next)
        armDwellIfNeeded(next)
    }

    /// Arms the retirement of a completed or cancelled report.
    ///
    /// A failed report never dwells: it stands until something displaces it or a
    /// fresh gesture clears it.
    private func armDwellIfNeeded(_ report: ClipboardTransferReport) {
        guard case .finished(let finish) = report, finish.failure == nil else { return }
        dwell = clock.schedule(after: Self.dwellSeconds) { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.clearFinished()
        }
    }
}
