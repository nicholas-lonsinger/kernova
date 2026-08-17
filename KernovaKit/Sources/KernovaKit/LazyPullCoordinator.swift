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
    /// The pull was cancelled — by `failAll` (channel close / supersession /
    /// release), or by this waiter leaving it.
    case cancelled
}

/// One in-flight pull per `transfer_id`, shared by every caller that asks for it.
///
/// The first caller **starts** the pull — inside `start` it registers the
/// receiver's awaiter and puts the `ClipboardRequest` on the wire — and every
/// caller after it **joins**: one slot, one awaiter, one request, and one outcome
/// handed to all of them. Nothing displaces anything, so a paste-time provider
/// fire and the window's preview fetch for the same representation share the
/// transfer instead of arbitrating over it.
///
/// Waiters come in two kinds:
///
/// - A **synchronous** waiter (``pull(transferID:timeout:onProgress:retire:start:)``)
///   holds the calling thread. At the base of the main run loop the wait runs the
///   application's event loop (`NestedEventLoopWait`), so the app keeps drawing,
///   dispatching input and running main-queue work; everywhere else it parks on a
///   semaphore, and there `deliver`/`abort`/`failAll` MUST come from another
///   thread — routed through the parked one, the wakeup could never run.
/// - An **asynchronous** waiter (``join(transferID:timeout:onProgress:retire:start:onResolve:)``)
///   hands over a callback, invoked from whichever thread resolved the slot. So
///   an `async` caller's resolution never crosses the main thread a synchronous
///   waiter may be holding.
///
/// The starter owns the pull's lifecycle: its `timeout` governs the slot's
/// inactivity backstop, and its `retire` releases the awaiter whenever the slot
/// ends by a route other than that awaiter firing — in the same critical section
/// that frees the id, so the next pull to take that id never has its own awaiter
/// released by this one. A slot that ends while `start` is still running leaves
/// that debt to the starting thread, which pays it as soon as `start` returns
/// and the awaiter exists. **No waiter owns anything keyed by `transfer_id`** —
/// not a joiner, and not any waiter once it has its outcome, since by then the
/// slot has released the id and the next `pull` or `join` for it starts a fresh
/// pull.
public final class LazyPullCoordinator: @unchecked Sendable {
    /// One caller waiting on a pull; ``leave(_:)`` takes the handle back.
    ///
    /// `@unchecked Sendable`: `resolvedOutcome` is read and written under the
    /// waiter's own `lock`, and everything else is immutable.
    public final class Waiter: @unchecked Sendable {
        /// How this waiter is told its outcome.
        fileprivate enum Wakeup {
            /// A held thread: its semaphore, plus the event loop the wait is
            /// running when it holds the main run loop's base.
            case synchronous(DispatchSemaphore, NestedEventLoopWait?)
            /// A callback, run on whichever thread resolved the slot.
            case asynchronous(@Sendable (LazyPullOutcome) -> Void)
        }

        fileprivate let transferID: UInt64
        fileprivate let onProgress: (@Sendable (Int, Int) -> Void)?
        private let wakeup: Wakeup
        private let lock = NSLock()
        private var resolvedOutcome: LazyPullOutcome?

        fileprivate init(
            transferID: UInt64, wakeup: Wakeup, onProgress: (@Sendable (Int, Int) -> Void)?
        ) {
            self.transferID = transferID
            self.wakeup = wakeup
            self.onProgress = onProgress
        }

        /// This waiter's outcome, once the slot has handed it one.
        fileprivate var outcome: LazyPullOutcome? { lock.withLock { resolvedOutcome } }

        /// Hands `outcome` over exactly once, waking the thread or calling back.
        fileprivate func resolve(_ outcome: LazyPullOutcome) {
            let isFirst = lock.withLock { () -> Bool in
                guard resolvedOutcome == nil else { return false }
                resolvedOutcome = outcome
                return true
            }
            guard isFirst else { return }
            switch wakeup {
            case .synchronous(let semaphore, let eventLoop):
                semaphore.signal()
                eventLoop?.wake()
            case .asynchronous(let onResolve):
                onResolve(outcome)
            }
        }
    }

    /// One in-flight pull and every waiter on it.
    ///
    /// `@unchecked Sendable`: the mutable state is read and written under the
    /// slot's own `lock`, which is taken while the coordinator's `lock` is held
    /// and never the reverse. `retire` runs under the coordinator's lock alone.
    private final class Slot: @unchecked Sendable {
        let transferID: UInt64
        /// The starter's inactivity window, governing every waiter on this pull.
        let timeout: TimeInterval
        /// Releases what the starter registered, for every route out but the
        /// awaiter's own delivery.
        let retire: @Sendable () -> Void
        let lock = NSLock()
        var waiters: [Waiter] = []
        var resolved = false
        /// Whether `start` has returned, so there is a registration for `retire`
        /// to release.
        var started = false
        /// Set when the slot ended while `start` was still running: the starting
        /// thread owes the `retire` nothing could run yet.
        var retireOwed = false
        /// Set by `progress`, consumed by each backstop tick: a window that saw a
        /// chunk re-arms instead of timing the pull out.
        var progressed = false
        var backstop: DispatchSourceTimer?

        init(transferID: UInt64, timeout: TimeInterval, retire: @escaping @Sendable () -> Void) {
            self.transferID = transferID
            self.timeout = timeout
            self.retire = retire
        }
    }

    private let lock = NSLock()
    private var slots: [UInt64: Slot] = [:]
    /// Where every slot's inactivity backstop fires — off the threads the pulls
    /// themselves hold.
    private let backstopQueue = DispatchQueue(label: "app.kernova.lazy-pull-backstop")

    /// Creates an idle coordinator.
    public init() {}

    /// Starts or joins the pull for `transferID`, holding the calling thread
    /// until it resolves.
    ///
    /// On the main thread the wait runs the event loop, so a resolve may arrive
    /// from main-queue work; on any other thread it parks, and the resolve MUST
    /// come from elsewhere or the wakeup deadlocks.
    ///
    /// - Parameters:
    ///   - transferID: correlates this pull with its `ClipboardRequest` and the
    ///     streamed reply.
    ///   - timeout: the inactivity window, honored only when this call starts the
    ///     pull; a joiner takes the starter's. Each chunk's `progress` re-arms it,
    ///     so a healthy transfer of any size never times out.
    ///   - onProgress: this waiter's byte-progress hook, fanned out from
    ///     `progress`.
    ///   - retire: releases the receiver awaiter `start` registered, for every
    ///     route out but that awaiter's own delivery. Runs at most once, under
    ///     the coordinator's lock — on whichever thread ends the slot, or on this
    ///     thread right after `start` returns when the slot ended while it ran —
    ///     so it must neither block nor call back into the coordinator.
    ///   - start: registers the awaiter and sends the request. Runs synchronously
    ///     on the calling thread, after the slot is registered, and only when this
    ///     call created it.
    /// - Returns: the outcome the pull resolved with.
    public func pull(
        transferID: UInt64,
        timeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)? = nil,
        retire: @escaping @Sendable () -> Void,
        start: () -> Void
    ) -> LazyPullOutcome {
        let semaphore = DispatchSemaphore(value: 0)
        // Decided before registration, so a resolve that races `start` finds it.
        let eventLoop = NestedEventLoopWait.current()
        let waiter = Waiter(
            transferID: transferID, wakeup: .synchronous(semaphore, eventLoop),
            onProgress: onProgress)
        // DIAGNOSTIC (scratch): time every main-thread pull and record its caller.
        let diagStart = Date()
        let diagStack = eventLoop != nil ? Thread.callStackSymbols.prefix(14).joined(separator: " | ") : ""
        defer {
            if eventLoop != nil {
                LazyPullDiagTimeline.record(
                    "MAIN-PULL id=\(transferID) took \(String(format: "%.2f", Date().timeIntervalSince(diagStart)))s from \(diagStart) stack: \(diagStack)"
                )
            }
        }
        let slot = enter(waiter, timeout: timeout, retire: retire, start: start)
        while true {
            // Each wait holds one slice and re-checks: the waiter's own outcome,
            // never the wait's return, decides — so a signal racing the deadline
            // is still honored, and the timeout *decision* stays the slot timer's
            // alone.
            if let eventLoop {
                eventLoop.wait(timeout: slot.timeout) { waiter.outcome != nil }
            } else {
                _ = semaphore.wait(timeout: .now() + slot.timeout)
            }
            if let outcome = waiter.outcome { return outcome }
        }
    }

    /// Starts or joins the pull for `transferID` without holding any thread.
    ///
    /// `onResolve` fires exactly once, on whichever thread resolved the slot — the
    /// receive lane, the backstop timer, or the caller of `failAll`/`leave` — so
    /// nothing it resumes depends on the main thread being free. The other
    /// parameters are ``pull(transferID:timeout:onProgress:retire:start:)``'s.
    ///
    /// - Returns: the waiter, for ``leave(_:)``.
    @discardableResult
    public func join(
        transferID: UInt64,
        timeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)? = nil,
        retire: @escaping @Sendable () -> Void,
        start: () -> Void,
        onResolve: @escaping @Sendable (LazyPullOutcome) -> Void
    ) -> Waiter {
        let waiter = Waiter(
            transferID: transferID, wakeup: .asynchronous(onResolve), onProgress: onProgress)
        _ = enter(waiter, timeout: timeout, retire: retire, start: start)
        return waiter
    }

    /// Drops one waiter from its pull, resolving it `.cancelled`.
    ///
    /// - Returns: whether the transfer is still someone's to resolve. `false`
    ///   only when this was the last waiter on a live pull — the slot is retired
    ///   and the caller owns tearing the transfer down. A waiter that already has
    ///   an outcome leaves nothing behind and reports `true`.
    @discardableResult
    public func leave(_ waiter: Waiter) -> Bool {
        var abandoned: Slot?
        let survives: Bool = lock.withLock {
            guard let slot = slots[waiter.transferID] else { return true }
            let stillWanted: Bool = slot.lock.withLock {
                guard let index = slot.waiters.firstIndex(where: { $0 === waiter }) else {
                    return true
                }
                slot.waiters.remove(at: index)
                guard slot.waiters.isEmpty else { return true }
                slot.resolved = true
                return false
            }
            guard !stillWanted else { return true }
            slots[slot.transferID] = nil
            retireSlot(slot)
            abandoned = slot
            return false
        }
        waiter.resolve(.cancelled)
        if let abandoned { cancelBackstop(abandoned) }
        return survives
    }

    /// Records that a chunk landed: re-arms the inactivity backstop and fans the
    /// byte counts out to every waiter's `onProgress`.
    ///
    /// Off-actor and idempotent; progress for a resolved or unknown pull is a
    /// no-op. The fanout runs under the slot's lock together with that check, so
    /// a chunk landing after the pull's terminal cannot reopen a readout the
    /// terminal closed.
    public func progress(_ transferID: UInt64, bytesReceived: Int, totalBytes: Int) {
        guard let slot = lock.withLock({ slots[transferID] }) else { return }
        slot.lock.withLock {
            guard !slot.resolved else { return }
            slot.progressed = true
            for waiter in slot.waiters { waiter.onProgress?(bytesReceived, totalBytes) }
        }
    }

    /// Resolves the pull for `transferID` with a completed representation.
    ///
    /// Off-actor and idempotent: a duplicate or post-timeout delivery is a
    /// no-op.
    public func deliver(_ transferID: UInt64, _ representation: ClipboardContent.Representation) {
        resolve(transferID, .delivered(representation), retiring: false)
    }

    /// Resolves the pull for `transferID` with a failure.
    ///
    /// Off-actor, idempotent.
    public func abort(_ transferID: UInt64, _ info: ClipboardStreamAbortInfo) {
        resolve(transferID, .aborted(info), retiring: false)
    }

    /// Resolves every waiter of every pull with `.cancelled`, retiring each slot.
    ///
    /// Called on channel teardown, a superseding offer, or a `ClipboardRelease`
    /// so an in-flight paste returns empty instead of blocking to the timeout.
    public func failAll() {
        let pending = lock.withLock { Array(slots.values) }
        for slot in pending { resolveSlot(slot, .cancelled, retiring: true) }
    }

    // MARK: - Private

    /// Registers `waiter` on the pull for its id, creating and starting the pull
    /// when it is the first to ask.
    private func enter(
        _ waiter: Waiter, timeout: TimeInterval, retire: @escaping @Sendable () -> Void,
        start: () -> Void
    ) -> Slot {
        let (slot, isStarter): (Slot, Bool) = lock.withLock {
            // A slot leaves `slots` in the same critical section that marks it
            // resolved, so one found here is always still live.
            if let existing = slots[waiter.transferID] {
                existing.lock.withLock { existing.waiters.append(waiter) }
                return (existing, false)
            }
            let slot = Slot(transferID: waiter.transferID, timeout: timeout, retire: retire)
            slot.waiters.append(waiter)
            slots[waiter.transferID] = slot
            return (slot, true)
        }
        guard isStarter else { return slot }
        armBackstop(slot)
        // Outside the lock, and only for the call that created the slot: one
        // awaiter and one request per pull, however many waiters join it.
        start()
        // The registration exists from here on, so anything that ended the slot
        // while `start` ran — a channel close, a release, the backstop — left the
        // release of that registration to this thread. Identity-checked like
        // `resolveSlot`'s removal: a fresh pull that took the id meanwhile owns
        // the registration under it now, and its own end releases it.
        lock.withLock {
            let owed = slot.lock.withLock { () -> Bool in
                let owed = slot.retireOwed
                slot.started = true
                slot.retireOwed = false
                return owed
            }
            if owed, slots[slot.transferID] == nil { slot.retire() }
        }
        return slot
    }

    /// Releases what `start` registered for `slot`, or leaves the debt to the
    /// thread still inside `start`.
    ///
    /// Caller holds the coordinator's `lock` and not `slot.lock`: freeing the id
    /// and releasing the awaiter registered against it are one step, so a fresh
    /// pull that takes the id next cannot have its own awaiter deregistered — or
    /// its reply blacklisted — by the slot it replaced.
    private func retireSlot(_ slot: Slot) {
        let started = slot.lock.withLock { () -> Bool in
            guard slot.started else {
                slot.retireOwed = true
                return false
            }
            return true
        }
        if started { slot.retire() }
    }

    /// Arms the slot's inactivity backstop: a window that sees no chunk resolves
    /// the pull `.timedOut`.
    private func armBackstop(_ slot: Slot) {
        let timer = DispatchSource.makeTimerSource(queue: backstopQueue)
        timer.schedule(deadline: .now() + slot.timeout, repeating: slot.timeout)
        timer.setEventHandler { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.backstopFired(slot)
        }
        // Resumed before it is handed over, so the store-or-cancel below can
        // never release a suspended source.
        timer.resume()
        let alreadyResolved = slot.lock.withLock { () -> Bool in
            guard !slot.resolved else { return true }
            slot.backstop = timer
            return false
        }
        if alreadyResolved { timer.cancel() }
    }

    private func cancelBackstop(_ slot: Slot) {
        let timer = slot.lock.withLock { () -> DispatchSourceTimer? in
            defer { slot.backstop = nil }
            return slot.backstop
        }
        timer?.cancel()
    }

    /// One backstop window boundary: re-arm if a chunk landed inside it, else
    /// give the pull up.
    private func backstopFired(_ slot: Slot) {
        let expired = slot.lock.withLock { () -> Bool in
            guard !slot.resolved else { return false }
            guard !slot.progressed else {
                slot.progressed = false
                return false
            }
            return true
        }
        guard expired else { return }
        resolveSlot(slot, .timedOut, retiring: true)
    }

    private func resolve(_ transferID: UInt64, _ outcome: LazyPullOutcome, retiring: Bool) {
        guard let slot = lock.withLock({ slots[transferID] }) else { return }
        resolveSlot(slot, outcome, retiring: retiring)
    }

    /// Ends `slot`, handing `outcome` to every waiter on it. Idempotent.
    ///
    /// `retiring` is true for every route but the awaiter's own delivery, where
    /// the receiver has already dropped the registration itself.
    private func resolveSlot(_ slot: Slot, _ outcome: LazyPullOutcome, retiring: Bool) {
        let waiters: [Waiter]? = lock.withLock {
            let taken: [Waiter]? = slot.lock.withLock {
                guard !slot.resolved else { return nil }
                slot.resolved = true
                defer { slot.waiters.removeAll() }
                return slot.waiters
            }
            guard taken != nil else { return nil }
            // Identity-checked: a fresh pull for the same id may already own the
            // key, and removing unconditionally would evict its live slot.
            if slots[slot.transferID] === slot { slots[slot.transferID] = nil }
            if retiring { retireSlot(slot) }
            return taken
        }
        guard let waiters else { return }
        cancelBackstop(slot)
        for waiter in waiters { waiter.resolve(outcome) }
    }

    #if DEBUG
    /// Number of pulls in flight.
    ///
    /// Test-only.
    var pendingSlotCountForTesting: Int { lock.withLock { slots.count } }

    /// Waiters sharing the pull for `transferID`.
    ///
    /// Test-only; `public` because the pull's clients live in other modules,
    /// whose tests assert on a preview and a paste having joined one transfer.
    public func waiterCountForTesting(_ transferID: UInt64) -> Int {
        guard let slot = lock.withLock({ slots[transferID] }) else { return 0 }
        return slot.lock.withLock { slot.waiters.count }
    }

    /// Runs one backstop window boundary for `transferID` — the tick the slot's
    /// timer would run — so a test drives the inactivity backstop deterministically
    /// instead of racing wall-clock scheduling.
    ///
    /// Test-only.
    func elapseBackstopWindowForTesting(_ transferID: UInt64) {
        guard let slot = lock.withLock({ slots[transferID] }) else { return }
        backstopFired(slot)
    }
    #endif
}

// DIAGNOSTIC (scratch branch only).
public enum LazyPullDiagTimeline {
    nonisolated(unsafe) private static var entries: [String] = []
    private static let lock = NSLock()
    public static func record(_ line: String) { lock.withLock { entries.append("[\(Date())] " + line) } }
    public static func dump() -> String { lock.withLock { entries.suffix(40).joined(separator: "\n") } }
}
