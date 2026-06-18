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
    }

    private let lock = NSLock()
    private var slots: [UInt64: Slot] = [:]

    /// Creates an idle coordinator.
    public init() {}

    /// Sends a request (via `send`) and blocks the calling thread until the
    /// matching transfer is delivered, aborts, is cancelled, or the timeout
    /// fires.
    ///
    /// The slot is registered **before** `send` runs so a fast completion can't
    /// be missed. MUST be called off the thread that `deliver`/`abort`/`failAll`
    /// run on (e.g. off the guest agent's main thread), or the wakeup deadlocks.
    ///
    /// - Parameters:
    ///   - transferID: correlates this pull with its `ClipboardRequest` and the
    ///     streamed reply.
    ///   - timeout: backstop ceiling on the block (see
    ///     `ClipboardStreamTuning.lazyPullTimeout`).
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
        lock.withLock { slots[transferID] = slot }
        send()
        let waitResult = slot.semaphore.wait(timeout: .now() + timeout.timeInterval)
        return lock.withLock {
            slots[transferID] = nil
            if waitResult == .timedOut && !slot.resolved {
                slot.resolved = true
                slot.outcome = .timedOut
            }
            return slot.outcome
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
        if shouldSignal { slot.semaphore.signal() }
    }

    #if DEBUG
    /// Number of pulls currently blocked.
    ///
    /// Test-only.
    var pendingSlotCountForTesting: Int { lock.withLock { slots.count } }
    #endif
}
