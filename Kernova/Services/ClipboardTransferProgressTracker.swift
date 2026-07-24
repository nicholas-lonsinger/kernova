import Foundation
import KernovaKit

/// Off-main authority for in-flight clipboard transfer progress.
///
/// `ClipboardStreamSender`/`Receiver` fire their progress callbacks off the main
/// actor (on a transfer's serial queue), so the raw cumulative byte counts land
/// here under a lock. `VsockClipboardService` then projects the most-significant
/// *revealed* transfer onto its `@MainActor` `transferProgress` via a coalesced,
/// rate-bounded hop.
///
/// "Revealed" is the time-based reveal gate: a transfer is recorded on its first
/// chunk but only enters the projection once the service's reveal `Task` marks it
/// revealed (after the reveal delay), so a transfer that finishes faster never
/// shows a bar. `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class ClipboardTransferProgressTracker: @unchecked Sendable {
    /// Outcome of `record`, telling the caller which main-actor follow-up to run.
    enum RecordOutcome: Equatable {
        /// First chunk for this transfer — the caller should arm its reveal `Task`.
        case created
        /// A subsequent chunk that the throttle admits and no flush is queued —
        /// schedule a coalesced flush.
        case updatedScheduleFlush
        /// A subsequent chunk that changes nothing observable yet — do nothing.
        ///
        /// Either a flush is already queued (it will read the freshest bytes, so
        /// updates conflate), the transfer isn't revealed (it contributes nothing
        /// to the projection), or the shared throttle suppressed it. The recorded
        /// bytes still advanced, so whatever flush comes next publishes them.
        case updatedSuppressed
    }

    private struct Entry {
        let direction: ClipboardTransferProgress.Direction
        var bytes: Int
        let total: Int
        let label: String?
        var revealed: Bool
        /// This transfer's share of the republish-rate bound — the same
        /// `FetchProgressThrottle` policy the File Provider pull's two progress
        /// consumers use (~1% of the total or ~100 ms apart, always the final
        /// chunk).
        ///
        /// Per entry, not per tracker: the coalescer models one byte stream with a
        /// byte watermark, and the tracker can hold several concurrent transfers
        /// (a folder copy's children) whose byte counts are unrelated. A reference
        /// type, so it survives `Entry`'s copy-in/copy-out through `entries`.
        let coalescer = FetchProgressCoalescer()
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    /// Conflation flag: set when an `.updatedScheduleFlush` is handed out, cleared
    /// by `consumeFlush`, so at most one main-actor flush is ever queued at a time.
    ///
    /// This bounds the flush *queue depth*; each entry's `coalescer` bounds the
    /// republish *rate*.
    private var flushScheduled = false

    /// Records cumulative progress for a transfer, creating its entry on the first
    /// chunk.
    ///
    /// Bytes only ever move forward (`max`) so a reordered callback can't regress
    /// the bar — and they advance on *every* chunk, including a suppressed one, so
    /// the next flush always publishes the freshest count.
    ///
    /// A chunk only earns a flush when it can actually change what's on screen:
    /// nothing is queued yet, the transfer is revealed (an unrevealed one is absent
    /// from the projection, so flushing for it is a guaranteed no-op publish), and
    /// the shared `FetchProgressCoalescer` admits it. That last check runs last
    /// because it *mutates* the watermarks on the admitted path — running it ahead
    /// of the cheaper gates would advance them for updates that were never
    /// published.
    func record(
        _ id: UInt64,
        direction: ClipboardTransferProgress.Direction,
        bytes: Int,
        total: Int,
        label: String?
    ) -> RecordOutcome {
        lock.withLock {
            if var entry = entries[id] {
                entry.bytes = max(entry.bytes, bytes)
                entries[id] = entry
                if flushScheduled { return .updatedSuppressed }
                guard entry.revealed else { return .updatedSuppressed }
                guard
                    entry.coalescer.shouldForward(
                        bytesTransferred: UInt64(max(entry.bytes, 0)),
                        totalBytes: UInt64(max(entry.total, 0)))
                else { return .updatedSuppressed }
                flushScheduled = true
                return .updatedScheduleFlush
            }
            entries[id] = Entry(
                direction: direction, bytes: bytes, total: total, label: label, revealed: false)
            return .created
        }
    }

    /// Marks a transfer visible.
    ///
    /// Returns `false` if it already finished, so a reveal `Task` firing after
    /// completion is a no-op.
    func reveal(_ id: UInt64) -> Bool {
        lock.withLock {
            guard var entry = entries[id] else { return false }
            entry.revealed = true
            entries[id] = entry
            return true
        }
    }

    /// Drops a finished or aborted transfer.
    func finish(_ id: UInt64) {
        lock.withLock { entries[id] = nil }
    }

    /// Drops every transfer (channel teardown / `stop()`).
    func clearAll() {
        lock.withLock {
            entries.removeAll()
            flushScheduled = false
        }
    }

    /// Clears the conflation flag and returns the current projection — the
    /// coalesced-flush path (a queued main-actor flush).
    ///
    /// Reading the freshest bytes here is why interim `.updatedSuppressed` updates
    /// need no own flush.
    func consumeFlush() -> ClipboardTransferProgress? {
        lock.withLock {
            flushScheduled = false
            return projectionLocked()
        }
    }

    /// The most-significant revealed transfer, without touching the conflation
    /// flag — the reveal/finish refresh path.
    func projection() -> ClipboardTransferProgress? {
        lock.withLock { projectionLocked() }
    }

    /// Most-significant revealed transfer — the one with the most bytes *remaining*
    /// (ties broken by the smallest transfer id), or `nil` when none is revealed.
    ///
    /// Ranking by bytes-remaining (not largest-total) means a just-completed
    /// transfer lingering at 100% (0 remaining, until its terminal removes it)
    /// never masks a freshly-started active one — which would otherwise show the
    /// bar at 100% and then visibly drop to the new transfer's level. Caller holds
    /// `lock`.
    private func projectionLocked() -> ClipboardTransferProgress? {
        func remaining(_ entry: Entry) -> Int { entry.total - min(max(entry.bytes, 0), entry.total) }
        let winner = entries.filter { $0.value.revealed }
            .min { lhs, rhs in
                let lhsRemaining = remaining(lhs.value)
                let rhsRemaining = remaining(rhs.value)
                if lhsRemaining != rhsRemaining { return lhsRemaining > rhsRemaining }
                return lhs.key < rhs.key
            }
        guard let entry = winner?.value else { return nil }
        return ClipboardTransferProgress(
            direction: entry.direction,
            bytesTransferred: min(max(entry.bytes, 0), entry.total),
            totalBytes: entry.total,
            label: entry.label)
    }
}
