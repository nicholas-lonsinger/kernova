import Foundation

/// Off-main authority for in-flight clipboard transfer progress.
///
/// `ClipboardStreamSender`/`Receiver` fire their progress callbacks off the main
/// actor (on a transfer's serial queue), so the raw cumulative byte counts land
/// here under a lock. `VsockClipboardService` then projects the most-significant
/// *revealed* transfer onto its `@MainActor` `transferProgress` via a coalesced,
/// rate-throttled hop.
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
        /// A subsequent chunk and no flush is queued — schedule a coalesced flush.
        ///
        /// The caller defers that flush by its own throttle interval; the flag
        /// stays set for the whole interval, so this is handed out at most once
        /// per interval — which is what bounds the republish *rate*, not just the
        /// queue depth.
        case updatedScheduleFlush
        /// A subsequent chunk but a flush is already queued — do nothing (the
        /// queued flush will read the freshest bytes, so updates conflate). Every
        /// chunk arriving during the caller's throttle interval lands here.
        case updatedSuppressed
    }

    private struct Entry {
        let direction: ClipboardTransferProgress.Direction
        var bytes: Int
        let total: Int
        let label: String?
        var revealed: Bool
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    /// Conflation flag: set when an `.updatedScheduleFlush` is handed out, cleared
    /// by `consumeFlush`, so at most one main-actor flush is ever queued at a time.
    ///
    /// Because the caller defers that flush by its throttle interval, the flag also
    /// stays set for the whole interval — so it bounds the flush *rate*, not just
    /// the queue depth: interim chunks return `.updatedSuppressed`.
    private var flushScheduled = false

    /// Records cumulative progress for a transfer, creating its entry on the first
    /// chunk.
    ///
    /// Bytes only ever move forward (`max`) so a reordered callback can't regress
    /// the bar.
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
