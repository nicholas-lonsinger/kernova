import Foundation
import KernovaSynchronization

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
    /// Nothing waited: the caller holds the main thread somewhere the live
    /// event-loop wait is unavailable, where the only alternative is parking the
    /// app for the transfer's length.
    case mainThreadUnavailable
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
///   holds the calling thread. On the main thread the wait runs the application's
///   event loop (`NestedEventLoopWait`), so the app keeps drawing, dispatching
///   input and running main-queue work; **the main thread is never parked**, and a
///   caller holding it where that wait is unavailable is refused
///   (`.mainThreadUnavailable`) rather than frozen. Off the main thread the wait
///   parks on a semaphore, and there `deliver`/`abort`/`failAll` MUST come from
///   another thread — routed through the parked one, the wakeup could never run.
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
final class LazyPullCoordinator: Sendable {
    /// One caller waiting on a pull; ``leave(_:)`` takes the handle back.
    final class Waiter: Sendable {
        /// How this waiter is told its outcome.
        fileprivate enum Wakeup: Sendable {
            /// A held thread: its semaphore, plus the event loop the wait is
            /// running when it holds the main run loop's base.
            case synchronous(DispatchSemaphore, NestedEventLoopWait?)
            /// A callback, run on whichever thread resolved the slot.
            case asynchronous(@Sendable (LazyPullOutcome) -> Void)
        }

        fileprivate let transferID: UInt64
        fileprivate let onProgress: (@Sendable (Int, Int) -> Void)?
        private let wakeup: Wakeup
        /// Set once, by whichever of the slot's end and a ``leave(_:)`` comes
        /// first; the held thread's wait reads it.
        private let resolvedOutcome = Locked<LazyPullOutcome?>(nil)

        fileprivate init(
            transferID: UInt64, wakeup: Wakeup, onProgress: (@Sendable (Int, Int) -> Void)?
        ) {
            self.transferID = transferID
            self.wakeup = wakeup
            self.onProgress = onProgress
        }

        /// This waiter's outcome, once the slot has handed it one.
        fileprivate var outcome: LazyPullOutcome? { resolvedOutcome.withLock { $0 } }

        /// Hands `outcome` over exactly once, waking the thread or calling back.
        fileprivate func resolve(_ outcome: LazyPullOutcome) {
            let isFirst = resolvedOutcome.withLock { resolved -> Bool in
                guard resolved == nil else { return false }
                resolved = outcome
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
    /// A slot is live exactly while it is in ``State/slots``: every route that
    /// ends it removes it in the same critical section.
    private struct Slot: Sendable {
        /// Tells this pull apart from a later one that takes the same id.
        let serial: UInt64
        /// The starter's inactivity window, governing every waiter on this pull.
        let timeout: TimeInterval
        /// Releases what the starter registered, for every route out but the
        /// awaiter's own delivery.
        let retire: @Sendable () -> Void
        var waiters: [Waiter] = []
        /// Whether `start` has returned, so there is a registration for `retire`
        /// to release.
        var started = false
        /// Set by `recordActivity`, consumed by each backstop tick: a window that
        /// saw bytes arrive re-arms instead of timing the pull out.
        var sawActivity = false
        var backstop: (any DispatchSourceTimer)?
    }

    private struct State: Sendable {
        var slots: [UInt64: Slot] = [:]
        var lastSerial: UInt64 = 0
        /// The `retire` of each slot that ended while its `start` was still
        /// running, keyed by serial: the starting thread owes it once `start`
        /// returns.
        var owedRetires: [UInt64: @Sendable () -> Void] = [:]

        /// Adds `waiter` to the live pull for its id, or creates the pull with
        /// `waiter` as its starter.
        mutating func enter(
            _ waiter: Waiter, timeout: TimeInterval, retire: @escaping @Sendable () -> Void
        ) -> (slot: Slot, isStarter: Bool) {
            if var existing = slots[waiter.transferID] {
                existing.waiters.append(waiter)
                slots[waiter.transferID] = existing
                return (existing, false)
            }
            lastSerial &+= 1
            let slot = Slot(serial: lastSerial, timeout: timeout, retire: retire, waiters: [waiter])
            slots[waiter.transferID] = slot
            return (slot, true)
        }

        /// Records that the starter's `start` returned, paying the `retire` a
        /// slot that ended meanwhile left owed.
        ///
        /// Paid only while the id is free: a fresh pull that took it meanwhile
        /// owns the registration under it now, and its own end releases it.
        mutating func markStarted(transferID: UInt64, serial: UInt64) {
            if slots[transferID]?.serial == serial {
                slots[transferID]?.started = true
                return
            }
            if let retire = owedRetires.removeValue(forKey: serial), slots[transferID] == nil {
                retire()
            }
        }

        /// Ends the live slot for `transferID` — only the one `serial` names,
        /// when given — and returns it.
        ///
        /// `retiring` is true for every route but the awaiter's own delivery,
        /// where the receiver has already dropped the registration itself.
        mutating func end(_ transferID: UInt64, serial: UInt64? = nil, retiring: Bool) -> Slot? {
            guard let slot = slots[transferID], serial.map({ $0 == slot.serial }) ?? true else {
                return nil
            }
            slots[transferID] = nil
            if retiring { retire(slot) }
            return slot
        }

        /// Releases what `start` registered for `slot`, or leaves the debt to
        /// the thread still inside `start`.
        ///
        /// Runs in the critical section that freed the id: freeing it and
        /// releasing the awaiter registered against it are one step, so a fresh
        /// pull that takes the id next cannot have its own awaiter deregistered
        /// — or its reply blacklisted — by the slot it replaced.
        mutating func retire(_ slot: Slot) {
            if slot.started {
                slot.retire()
            } else {
                owedRetires[slot.serial] = slot.retire
            }
        }
    }

    private let state = Locked(State())
    /// Where every slot's inactivity backstop fires — off the threads the pulls
    /// themselves hold.
    private let backstopQueue = DispatchQueue(label: "app.kernova.lazy-pull-backstop")

    /// Vends the event-loop wait a synchronous pull on the calling thread runs,
    /// or `nil` where that caller must park — refused on the main thread.
    private let eventLoopWait: @Sendable () -> NestedEventLoopWait?

    /// Creates an idle coordinator whose synchronous pulls take their wait from
    /// `eventLoopWait`.
    init(eventLoopWait: @escaping @Sendable () -> NestedEventLoopWait? = NestedEventLoopWait.current) {
        self.eventLoopWait = eventLoopWait
    }

    /// Starts or joins the pull for `transferID`, holding the calling thread
    /// until it resolves.
    ///
    /// On the main thread the wait runs the event loop, so a resolve may arrive
    /// from main-queue work; on any other thread it parks, and the resolve MUST
    /// come from elsewhere or the wakeup deadlocks. A main-thread caller the
    /// event loop is unavailable to gets `.mainThreadUnavailable` without a pull
    /// being started at all.
    ///
    /// - Parameters:
    ///   - transferID: correlates this pull with its `ClipboardRequest` and the
    ///     streamed reply.
    ///   - timeout: the inactivity window, honored only when this call starts the
    ///     pull; a joiner takes the starter's. Every `recordActivity` re-arms it,
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
    func pull(
        transferID: UInt64,
        timeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)? = nil,
        retire: @escaping @Sendable () -> Void,
        start: () -> Void
    ) -> LazyPullOutcome {
        // Decided before registration, so a resolve that races `start` finds it.
        let eventLoop = eventLoopWait()
        // The main thread is never parked. A wait source vends no wait on the
        // main thread where a nested wait would have to dispatch events another
        // loop owns — the live one, inside a tracking or modal loop. The
        // semaphore below is the off-main branch, and taking it here would
        // freeze the app for the length of the transfer. Refusing costs this
        // one fire, which the caller reports; parking would cost every frame
        // until the pull resolved.
        guard eventLoop != nil || !Thread.isMainThread else { return .mainThreadUnavailable }
        let semaphore = DispatchSemaphore(value: 0)
        let waiter = Waiter(
            transferID: transferID, wakeup: .synchronous(semaphore, eventLoop),
            onProgress: onProgress)
        let slotTimeout = enter(waiter, timeout: timeout, retire: retire, start: start)
        while true {
            // Each wait holds one slice and re-checks: the waiter's own outcome,
            // never the wait's return, decides — so a signal racing the deadline
            // is still honored, and the timeout *decision* stays the slot timer's
            // alone.
            if let eventLoop {
                eventLoop.wait(timeout: slotTimeout) { waiter.outcome != nil }
            } else {
                _ = semaphore.wait(timeout: .now() + slotTimeout)
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
    func join(
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
    func leave(_ waiter: Waiter) -> Bool {
        let abandoned = state.withLock { state -> Slot? in
            guard var slot = state.slots[waiter.transferID],
                let index = slot.waiters.firstIndex(where: { $0 === waiter })
            else { return nil }
            slot.waiters.remove(at: index)
            guard slot.waiters.isEmpty else {
                state.slots[waiter.transferID] = slot
                return nil
            }
            return state.end(waiter.transferID, serial: slot.serial, retiring: true)
        }
        waiter.resolve(.cancelled)
        abandoned?.backstop?.cancel()
        return abandoned == nil
    }

    /// Fans one transfer's payload figure out to every waiter's `onProgress`.
    ///
    /// Off-actor; progress for a resolved or unknown pull is a no-op. The fanout
    /// runs under the lock together with that check, so a figure landing after
    /// the pull's terminal cannot reopen a readout the terminal closed.
    func progress(_ transferID: UInt64, bytesReceived: Int, totalBytes: Int) {
        state.withLock { state in
            guard let slot = state.slots[transferID] else { return }
            for waiter in slot.waiters { waiter.onProgress?(bytesReceived, totalBytes) }
        }
    }

    /// Records that bytes arrived for `transferID`, so the inactivity backstop
    /// re-arms at its next window boundary rather than timing the pull out.
    ///
    /// Off-actor and idempotent; activity for a resolved or unknown pull is a
    /// no-op.
    func recordActivity(_ transferID: UInt64) {
        state.withLock { $0.slots[transferID]?.sawActivity = true }
    }

    /// Resolves the pull for `transferID` with a completed representation.
    ///
    /// Off-actor and idempotent: a duplicate or post-timeout delivery is a
    /// no-op.
    func deliver(_ transferID: UInt64, _ representation: ClipboardContent.Representation) {
        finish(state.withLock { $0.end(transferID, retiring: false) }, .delivered(representation))
    }

    /// Resolves the pull for `transferID` with a failure.
    ///
    /// Off-actor, idempotent.
    func abort(_ transferID: UInt64, _ info: ClipboardStreamAbortInfo) {
        finish(state.withLock { $0.end(transferID, retiring: false) }, .aborted(info))
    }

    /// Resolves every waiter of every pull with `.cancelled`, retiring each slot.
    ///
    /// Called on channel teardown, a superseding offer, or a `ClipboardRelease`
    /// so an in-flight paste returns empty instead of blocking to the timeout.
    func failAll() {
        let ended = state.withLock { state in
            Array(state.slots.keys).compactMap { state.end($0, retiring: true) }
        }
        for slot in ended { finish(slot, .cancelled) }
    }

    // MARK: - Private

    /// Registers `waiter` on the pull for its id, creating and starting the pull
    /// when it is the first to ask.
    ///
    /// - Returns: the pull's inactivity window.
    private func enter(
        _ waiter: Waiter, timeout: TimeInterval, retire: @escaping @Sendable () -> Void,
        start: () -> Void
    ) -> TimeInterval {
        let (slot, isStarter) = state.withLock { $0.enter(waiter, timeout: timeout, retire: retire) }
        guard isStarter else { return slot.timeout }
        armBackstop(transferID: waiter.transferID, slot: slot)
        // Outside the lock, and only for the call that created the slot: one
        // awaiter and one request per pull, however many waiters join it.
        start()
        // The registration exists from here on, so anything that ended the slot
        // while `start` ran — a channel close, a release, the backstop — left the
        // release of that registration to this thread.
        state.withLock { $0.markStarted(transferID: waiter.transferID, serial: slot.serial) }
        return slot.timeout
    }

    /// Arms the slot's inactivity backstop: a window that sees no bytes arrive
    /// resolves the pull `.timedOut`.
    private func armBackstop(transferID: UInt64, slot: Slot) {
        let serial = slot.serial
        let timer = DispatchSource.makeTimerSource(queue: backstopQueue)
        timer.schedule(deadline: .now() + slot.timeout, repeating: slot.timeout)
        timer.setEventHandler { [weak self] in
            self?.backstopFired(transferID, serial: serial)
        }
        // Resumed before it is handed over, so the store-or-cancel below can
        // never release a suspended source.
        timer.resume()
        let stored = state.withLock { state -> Bool in
            guard state.slots[transferID]?.serial == serial else { return false }
            state.slots[transferID]?.backstop = timer
            return true
        }
        if !stored { timer.cancel() }
    }

    /// One backstop window boundary for the pull `serial` names, or for the
    /// live pull when `nil`: re-arm if bytes arrived inside it, else give the
    /// pull up.
    private func backstopFired(_ transferID: UInt64, serial: UInt64?) {
        let expired = state.withLock { state -> Slot? in
            guard let slot = state.slots[transferID], serial.map({ $0 == slot.serial }) ?? true
            else { return nil }
            guard !slot.sawActivity else {
                state.slots[transferID]?.sawActivity = false
                return nil
            }
            return state.end(transferID, serial: slot.serial, retiring: true)
        }
        finish(expired, .timedOut)
    }

    /// Hands `outcome` to every waiter of a slot just ended, if one was.
    private func finish(_ slot: Slot?, _ outcome: LazyPullOutcome) {
        guard let slot else { return }
        slot.backstop?.cancel()
        for waiter in slot.waiters { waiter.resolve(outcome) }
    }

    #if DEBUG
    /// Number of pulls in flight.
    ///
    /// Test-only.
    var pendingSlotCountForTesting: Int { state.withLock { $0.slots.count } }

    /// Waiters sharing the pull for `transferID`. Test-only.
    func waiterCountForTesting(_ transferID: UInt64) -> Int {
        state.withLock { $0.slots[transferID]?.waiters.count ?? 0 }
    }

    /// Runs one backstop window boundary for `transferID` — the tick the slot's
    /// timer would run — so a test drives the inactivity backstop deterministically
    /// instead of racing wall-clock scheduling.
    ///
    /// Test-only.
    func elapseBackstopWindowForTesting(_ transferID: UInt64) {
        backstopFired(transferID, serial: nil)
    }
    #endif
}
