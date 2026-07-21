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
    /// before it resolved (#500 — e.g. a File Provider fetch retried after its
    /// owner connection dropped mid-pull). The retry owns the id now; this
    /// caller must not touch any state keyed by `transferID` (unlike
    /// `.cancelled`, which the caller's own cleanup would otherwise do).
    case superseded
}

/// Bridges a synchronous, blocking consume (an `NSPasteboardItemDataProvider`
/// callback) to the asynchronous, off-actor stream receive.
///
/// The lazy clipboard path defers the `ClipboardRequest` to the moment the OS
/// asks the promise owner for a representation's bytes. That callback is
/// synchronous and runs on the owner's main thread, but the streamed receive
/// runs off the owning actor on the receiver's per-transfer queue. This
/// coordinator parks the calling thread on a per-`transfer_id` semaphore until
/// the receiver delivers (`deliver`/`abort`), the channel tears down
/// (`failAll`), or a backstop timeout fires — then returns the outcome.
///
/// ## Deadlock safety
/// `deliver`/`abort`/`failAll` must be invoked **off the blocked thread** — for
/// the guest provider that means off the agent's main thread. The wiring is
/// `ClipboardStreamReceiver.awaitTransfer` → these methods, fired on the
/// transfer's serial queue (never main). If the wakeup were routed through the
/// blocked thread it could never run.
///
/// `@unchecked Sendable`: the slot table is guarded by `lock`; each slot's
/// semaphore is the only cross-thread handoff.
public final class LazyPullCoordinator: @unchecked Sendable {
    /// One waiting consumer, keyed by `transfer_id`.
    private final class Slot {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: LazyPullOutcome = .cancelled
        var resolved = false
        /// Set by `heartbeat` when a chunk lands; consumed by `pull` at each
        /// window boundary to re-arm the inactivity backstop.
        var progressed = false
    }

    #if DEBUG
    /// Test seam: replaces the real timed semaphore wait at each window boundary in `pull`.
    ///
    /// Lets a test control precisely when a window "elapses" instead of
    /// racing real wall-clock scheduling. Defaults to a real timed wait
    /// identical to the Release-only path below; tests override it to make
    /// window-boundary re-arming deterministic. Test-only.
    var windowWaitForTesting: (@Sendable (DispatchSemaphore, Duration) -> Void) = { semaphore, timeout in
        _ = semaphore.wait(timeout: .now() + timeout.timeInterval)
    }
    #endif

    private let lock = NSLock()
    private var slots: [UInt64: Slot] = [:]
    /// Transfer ids cancelled (#464) before `pull` registered a slot for them.
    ///
    /// One-shot: `pull` consumes (removes) its own id the moment it runs,
    /// whether or not it was present — so this can never grow unboundedly, and
    /// a `transferID` that's never pulled leaves at most one stale entry (freed
    /// the next time that same id happens to be pulled, or simply harmless
    /// dead weight for the coordinator's lifetime otherwise).
    private var preCancelled: Set<UInt64> = []

    /// Creates an idle coordinator.
    public init() {}

    /// Sends a request (via `send`) and blocks the calling thread until the
    /// matching transfer is delivered, aborts, is cancelled, or the pull goes a
    /// full `timeout` window without progress.
    ///
    /// The slot is registered **before** `send` runs so a fast completion can't
    /// be missed. MUST be called off the thread that `deliver`/`abort`/`failAll`
    /// run on (e.g. off the guest agent's main thread), or the wakeup deadlocks.
    ///
    /// `timeout` is an **inactivity** window, not an absolute deadline: each
    /// `heartbeat` (one per chunk accepted off the wire — since #615 that is
    /// the receive lane's own signal, so it can run up to one credit window
    /// ahead of the staging writes) re-arms it, so a healthy
    /// transfer of any size never times out no matter how long it runs. The
    /// backstop fires only after a full window with no chunk *and* no terminal
    /// outcome — and the receiver's own 30 s stall timer normally aborts a dead
    /// transfer first. (An earlier absolute deadline silently killed large,
    /// still-progressing transfers that needed more than one window to stream.)
    /// The host runs the equivalent inactivity loop for the reverse direction in
    /// `VsockClipboardService.pull`.
    ///
    /// - Parameters:
    ///   - transferID: correlates this pull with its `ClipboardRequest` and the
    ///     streamed reply.
    ///   - timeout: inactivity window (see `ClipboardStreamTuning.lazyPullTimeout`).
    ///   - send: emits the `ClipboardRequest`; runs synchronously on the calling
    ///     thread after the slot is registered.
    /// - Returns: the outcome the matching transfer resolved with — delivered,
    ///   aborted, cancelled, or timed out.
    public func pull(
        transferID: UInt64,
        timeout: Duration = ClipboardStreamTuning.lazyPullTimeout,
        send: () -> Void
    ) -> LazyPullOutcome {
        let slot = Slot()
        // Consume any pre-cancel mark atomically with registering the slot: a
        // `cancelBeforeStart` that raced ahead of this call (#464 — a consumer
        // cancelling before the request was even sent) is honored here instead
        // of registering a slot nothing will ever resolve until the backstop
        // timeout, and `send` never runs — the request never goes out over the
        // wire for a fetch the consumer already gave up on.
        //
        // A pre-existing slot for the same id (#500 — e.g. a File Provider
        // fetch retried after its owner connection dropped mid-pull, so a
        // second concurrent `pull` for the identical `(generation, repIndex)`
        // registers) is captured and displaced here rather than silently
        // overwritten: the retry is always the live registration going
        // forward (the prior caller's connection is dead and can't deliver
        // its result), so per CLIPBOARD.md §9 the displaced pull is woken
        // immediately with `.superseded` instead of parking to its own
        // backstop timeout.
        let (alreadyCancelled, displaced): (Bool, Slot?) = lock.withLock {
            if preCancelled.remove(transferID) != nil { return (true, nil) }
            let prior = slots[transferID]
            slots[transferID] = slot
            return (false, prior)
        }
        if let displaced {
            // `resolveSlot` no-ops if `displaced` already resolved on its own
            // (e.g. it delivered a beat before being displaced) — its real
            // outcome wins, not a spurious supersede.
            resolveSlot(displaced, .superseded)
        }
        if alreadyCancelled { return .cancelled }
        send()
        while true {
            // The wait blocks one window; the slot's flags — not the wait result —
            // decide the outcome, so a signal that races the deadline is still
            // honored via `resolved` below.
            #if DEBUG
            windowWaitForTesting(slot.semaphore, timeout)
            #else
            _ = slot.semaphore.wait(timeout: .now() + timeout.timeInterval)
            #endif
            let outcome: LazyPullOutcome? = lock.withLock {
                // A terminal resolve (deliver/abort/cancel) sets `resolved` before
                // signaling, so it's observed here whether the wait was signaled or
                // raced the deadline.
                if slot.resolved {
                    // Identity-checked: if a later `pull` has since superseded
                    // this slot, `slots[transferID]` already points at ITS
                    // slot — removing unconditionally here would evict the
                    // successor's live registration out from under it (#500).
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
    /// no-op. Does not signal the semaphore — the blocked `pull` reads the flag
    /// when its current wait window elapses, so a heartbeat costs nothing while
    /// bytes flow.
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

    /// Cancels the pull for `transferID` (#464) whether or not it has reached
    /// `pull` yet.
    ///
    /// If a slot is already registered, resolves it immediately with
    /// `.cancelled` — the same effect as `abort`/`failAll`, just addressed by
    /// id. If `pull` hasn't been called yet for this id, marks it so the
    /// upcoming `pull` call resolves to `.cancelled` on arrival instead of
    /// registering a slot and sending a request the consumer already gave up
    /// on. Idempotent: a repeated or late call for an id with no slot and no
    /// pending mark just re-marks it, consumed by the next `pull` as usual.
    public func cancelBeforeStart(_ transferID: UInt64) {
        let slot: Slot? = lock.withLock {
            if let existing = slots[transferID] { return existing }
            preCancelled.insert(transferID)
            return nil
        }
        if let slot { resolveSlot(slot, .cancelled) }
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
        if shouldSignal { slot.semaphore.signal() }
    }

    #if DEBUG
    /// Number of pulls currently blocked.
    ///
    /// Test-only.
    var pendingSlotCountForTesting: Int { lock.withLock { slots.count } }

    /// Number of pre-cancel marks awaiting a `pull` call to consume them.
    ///
    /// Test-only.
    var preCancelledCountForTesting: Int { lock.withLock { preCancelled.count } }
    #endif
}
