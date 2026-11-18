import Foundation
import KernovaLogging

/// One peer's clipboard transfer state, as every surface renders it — the host
/// keeps one per VM.
///
/// Several producers publish here (a VM's clipboard service, its drop service,
/// its drag out), and the report is the highest-ranked running
/// operation, else the last one to finish, else nothing. Whatever the readout
/// leaves out is counted on it as ``ClipboardProgressSnapshot/pendingBehind``,
/// so work behind the bar is legible rather than absent. A refusal
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

    /// One live operation and its latest readout.
    ///
    /// Keyed by the operation's minted identity, which outlives it: an
    /// operation that goes away unended retires its entry by that identity
    /// from its `deinit`. The reference is weak, so the readout never keeps a
    /// producer alive; it is only what a Cancel reaches.
    private struct Live {
        let id: ClipboardTransferOperationID
        weak var operation: ClipboardTransferOperation?
        var snapshot: ClipboardProgressSnapshot
        var since: Date
    }

    /// Live operations in the order they first published a bar, which settles a
    /// tie between equal ranks.
    private var live: [Live] = []

    /// The last operation to finish, until something displaces it, the dwell
    /// retires it, or a caller clears it.
    private var lastFinish: ClipboardTransferFinish?

    /// Whether a repeat of ``lastFinish`` should collapse into it rather than be
    /// announced again.
    ///
    /// Cleared as soon as a later gesture announces itself — ``gestureBegan()``,
    /// or an operation opening a bar — so the same refusal raised by that
    /// gesture is news again. ``gestureBegan()`` covers the gesture that opens
    /// no bar: an operation whose transfers all end inside the reveal gate
    /// publishes no readout at all, and two gestures that each lost a file
    /// would otherwise reach the user as a single message.
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
                // Updated in place: moving it to the end on every progress tick
                // would hand the readout back and forth between two transfers
                // running side by side.
                live[index].snapshot = snapshot
                live[index].since = since
            } else {
                live.append(Live(id: operation.id, operation: operation, snapshot: snapshot, since: since))
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

    /// Records that a gesture has begun, so a repeat of what the last one
    /// reported is announced again rather than collapsed into it.
    ///
    /// A gesture says this whether or not it opens a bar: one that opens none —
    /// its transfers all ending inside the reveal gate, or a drag whose items
    /// all turn out to be unreadable, one the channel outlived, one whose offer
    /// never got away — leaves its refusal as the only trace of it, owed the
    /// message the identical refusal before it got. What stands is left alone:
    /// a report an earlier gesture raised is not this one's to clear.
    public func gestureBegan() {
        absorbsRepeats = false
    }

    /// Records a refusal raised without a transfer behind it — a pre-flight
    /// check, a peer error frame, a gesture that never opened a stream.
    public func finish(_ finish: ClipboardTransferFinish) {
        record(finish, startedAt: nil)
    }

    /// Records that `gesture`, begun at `startedAt`, delivered everything it
    /// asked for with no readout to dwell on: it clears the refusal a
    /// completion of it would displace.
    public func completed(_ gesture: ClipboardTransferGesture, startedAt: Date) {
        guard let standing = lastFinish, standing.failure != nil,
            !Self.keeps(standing, against: gesture, failed: false, startedAt: startedAt)
        else { return }
        clearFinished()
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
        if let standing = lastFinish, standing.failure != nil,
            Self.keeps(standing, against: finish.gesture, failed: finish.failure != nil, startedAt: startedAt)
        {
            recompute()
            return
        }
        lastFinish = finish
        absorbsRepeats = true
        failureAwaitsDisplacement = finish.failure != nil
        if let line = finish.logLine, finish.gesture.isMadeHere {
            Self.logger.log(.notice, "\(line, privacy: .public)")
        }
        recompute()
    }

    /// Whether the refusal `standing` stands over a finish of `gesture` —
    /// `failed` or not, by an operation begun at `startedAt` when it ran one.
    private static func keeps(
        _ standing: ClipboardTransferFinish, against gesture: ClipboardTransferGesture, failed: Bool,
        startedAt: Date?
    ) -> Bool {
        // A gesture the peer made answers the peer's user, so nothing it ends
        // with disproves what this side's user is owed — including a refusal
        // of its own, which the surfaces that interrupt would not present
        // here anyway.
        let answersTheOtherUser = !gesture.isMadeHere && standing.gesture.isMadeHere
        // Running to the end says nothing about a transfer that failed
        // alongside; a refusal older than the operation is one the operation
        // retried, so that one is cleared.
        let raisedDuringTheOperation = !failed && (startedAt.map { standing.date >= $0 } ?? false)
        return answersTheOtherUser || raisedDuringTheOperation
    }

    /// The one running readout every surface shows.
    ///
    /// Ranked by ``ClipboardTransferGesture/readoutRank`` rather than by which
    /// published last, so work started under a gesture someone is waiting on
    /// never takes the bar off it; equal ranks fall back to the last to open a
    /// bar.
    private func shownReadout() -> Live? {
        let rank = live.map(\.snapshot.gesture.readoutRank).max()
        return live.last { $0.snapshot.gesture.readoutRank == rank }
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
