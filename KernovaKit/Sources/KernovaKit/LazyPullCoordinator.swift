import Foundation

/// The result of a lazy pull: a materialized representation, or why no bytes
/// arrived.
public enum LazyPullOutcome: Sendable {
    /// The transfer completed; its bytes are resident (`.inMemory`) or staged to
    /// a committed temp file (`.file`).
    case delivered(ClipboardContent.Representation)
    /// The transfer failed (peer abort, disk full, digest mismatch, …).
    case aborted(ClipboardStreamAbortInfo)
    /// No outcome arrived within the pull timeout (the backstop fired).
    case timedOut
    /// The pull was cancelled by `failAll` (channel close / supersession /
    /// release).
    case cancelled
    /// A newer `pull` call for the identical `transferID` displaced this one
    /// before it resolved. The retry owns the id now, so this caller must not
    /// touch any state keyed by `transferID` — unlike `.cancelled`, where its
    /// own cleanup is expected.
    case superseded
}

/// Bridges a synchronous consume (an `NSPasteboardItemDataProvider` callback)
/// to the asynchronous, off-actor stream receive: the calling thread is held,
/// per `transfer_id`, until the transfer resolves.
///
/// How it is held depends on the thread. At the base of the main run loop the
/// wait runs the application's event loop (`NestedEventLoopWait`), so the app
/// keeps drawing, dispatching input and running main-queue work — a wait that
/// is reentrant by design. Everywhere else it parks on a semaphore, and there
/// `deliver`/`abort`/`failAll` MUST come from another thread: routed through the
/// parked one, the wakeup could never run.
public final class LazyPullCoordinator: @unchecked Sendable {
    /// One waiting consumer, keyed by `transfer_id`.
    ///
    /// `@unchecked Sendable`: the flags are read and written under the
    /// coordinator's `lock`; `eventLoop` is set before the slot is registered.
    private final class Slot: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: LazyPullOutcome = .cancelled
        var resolved = false
        /// Set by `heartbeat` when a chunk lands; consumed by `pull` at each
        /// window boundary to re-arm the inactivity backstop.
        var progressed = false
        /// The event loop a main-thread `pull` is running, so a resolve can
        /// break it; `nil` for a parked pull.
        var eventLoop: NestedEventLoopWait?
    }

    #if DEBUG
    /// Test seam: replaces the real timed semaphore wait at each window boundary
    /// of a parked `pull`.
    ///
    /// Test-only; defaults to a wait identical to the Release path below. Lets a
    /// test control when a window "elapses" instead of racing wall-clock
    /// scheduling.
    var windowWaitForTesting: (@Sendable (DispatchSemaphore, TimeInterval) -> Void) = { semaphore, timeout in
        _ = semaphore.wait(timeout: .now() + timeout)
    }
    #endif

    private let lock = NSLock()
    private var slots: [UInt64: Slot] = [:]

    /// Creates an idle coordinator.
    public init() {}

    /// Sends a request (via `send`) and holds the calling thread until the
    /// matching transfer is delivered, aborts, is cancelled, or the pull goes a
    /// full `timeout` window without progress.
    ///
    /// The slot is registered **before** `send` runs so a fast completion can't
    /// be missed. On the main thread the wait runs the event loop, so a resolve
    /// may arrive from main-queue work; on any other thread it parks, and the
    /// resolve MUST come from elsewhere or the wakeup deadlocks. `timeout` is an
    /// **inactivity** window, not an absolute deadline: each `heartbeat` re-arms
    /// it, so a healthy transfer of any size never times out.
    ///
    /// - Parameters:
    ///   - transferID: correlates this pull with its `ClipboardRequest` and the
    ///     streamed reply.
    ///   - timeout: inactivity window (see `ClipboardStreamTuning.lazyPullTimeout`).
    ///   - send: emits the `ClipboardRequest`; runs synchronously on the calling
    ///     thread after the slot is registered.
    /// - Returns: the outcome the matching transfer resolved with.
    public func pull(
        transferID: UInt64,
        timeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        send: () -> Void
    ) -> LazyPullOutcome {
        let slot = Slot()
        // Decided before registration, so a resolve that races `send` finds it.
        slot.eventLoop = NestedEventLoopWait.current()
        // A pre-existing slot for the same id is displaced rather than silently
        // overwritten: the retry is the live registration going forward, so the
        // displaced pull is woken immediately with `.superseded` instead of
        // parking to its backstop (CLIPBOARD.md §9).
        let displaced: Slot? = lock.withLock {
            let prior = slots[transferID]
            slots[transferID] = slot
            return prior
        }
        if let displaced {
            // No-ops if `displaced` already resolved on its own, so its real
            // outcome wins over a spurious supersede.
            resolveSlot(displaced, .superseded)
        }
        send()
        while true {
            // The wait holds one window; the slot's flags — not the wait result —
            // decide the outcome, so a signal that races the deadline is still
            // honored via `resolved` below.
            if let eventLoop = slot.eventLoop {
                eventLoop.wait(timeout: timeout) { lock.withLock { slot.resolved } }
            } else {
                #if DEBUG
                windowWaitForTesting(slot.semaphore, timeout)
                #else
                _ = slot.semaphore.wait(timeout: .now() + timeout)
                #endif
            }
            let outcome: LazyPullOutcome? = lock.withLock {
                if slot.resolved {
                    // Identity-checked: removing unconditionally would evict a
                    // successor pull's live registration out from under it.
                    if slots[transferID] === slot { slots[transferID] = nil }
                    return slot.outcome
                }
                // The window elapsed with no terminal outcome. If a chunk landed
                // during it (heartbeat), re-arm; otherwise give up.
                if slot.progressed {
                    slot.progressed = false
                    return nil
                }
                slot.resolved = true
                slot.outcome = .timedOut
                if slots[transferID] === slot { slots[transferID] = nil }
                return .timedOut
            }
            if let outcome { return outcome }
        }
    }

    /// Re-arms the inactivity backstop for `transferID`: records that a chunk
    /// landed so the blocked `pull` keeps waiting past the next window boundary.
    ///
    /// Off-actor and idempotent; a heartbeat for a resolved or unknown pull is a
    /// no-op.
    public func heartbeat(_ transferID: UInt64) {
        lock.withLock {
            guard let slot = slots[transferID], !slot.resolved else { return }
            slot.progressed = true
        }
    }

    /// Resolves the pull for `transferID` with a completed representation.
    ///
    /// Off-actor and idempotent: a duplicate or post-timeout delivery is a
    /// no-op.
    public func deliver(_ transferID: UInt64, _ representation: ClipboardContent.Representation) {
        resolve(transferID, .delivered(representation))
    }

    /// Resolves the pull for `transferID` with a failure.
    ///
    /// Off-actor, idempotent.
    public func abort(_ transferID: UInt64, _ info: ClipboardStreamAbortInfo) {
        resolve(transferID, .aborted(info))
    }

    /// Unblocks every waiting pull with `.cancelled`.
    ///
    /// Called on channel teardown, a superseding offer, or a `ClipboardRelease`
    /// so an in-flight paste returns empty instead of blocking to the timeout.
    public func failAll() {
        let pending = lock.withLock { Array(slots.values) }
        for slot in pending { resolveSlot(slot, .cancelled) }
    }

    // MARK: - Private

    private func resolve(_ transferID: UInt64, _ outcome: LazyPullOutcome) {
        guard let slot = lock.withLock({ slots[transferID] }) else { return }
        resolveSlot(slot, outcome)
    }

    private func resolveSlot(_ slot: Slot, _ outcome: LazyPullOutcome) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !slot.resolved else { return false }
            slot.resolved = true
            slot.outcome = outcome
            return true
        }
        guard shouldSignal else { return }
        slot.semaphore.signal()
        slot.eventLoop?.wake()
    }

    #if DEBUG
    /// Number of pulls currently waiting.
    ///
    /// Test-only.
    var pendingSlotCountForTesting: Int { lock.withLock { slots.count } }
    #endif
}
