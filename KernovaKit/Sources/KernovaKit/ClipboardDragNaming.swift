import Foundation
import KernovaSynchronization

/// The host's naming of the promised items in the guest's drags: asking for
/// them (`DragResolve`), the guest's answer (`STAGE_RESOLVING`, or a refusal),
/// and the names they take (`DragNames`), item by item.
///
/// Every reply is recorded here on the session's reader thread, before any hop
/// to the main actor: the thread waiting for a name can be the main thread
/// itself, held inside the Mac drag's tracking loop, which runs nothing queued
/// to main until it returns.
///
/// An item's name, or the guest saying it will not name it, stands until the
/// drag is retired. So does a failure of the whole drag — the hand-off
/// failing, the resolve refused, a deadline passing — for every item not
/// already settled, so later asks are answered at once.
final class ClipboardDragNaming: Sendable {
    /// Where one drag's `DragResolve` exchange is.
    private enum Exchange: Sendable {
        /// Nothing has asked.
        case idle
        /// `DragResolve` is away; the guest has not answered.
        case requested
        /// The guest answered `STAGE_RESOLVING`, so its names follow.
        case acknowledged
    }

    /// One drag the guest offered, from its `DragOffer` to its retirement.
    private struct Record: Sendable {
        /// Each promised item's index, and whether it is a directory.
        let promised: [Int: Bool]
        var exchange: Exchange = .idle
        /// Each promised item the guest has named, its name made safe.
        var names: [Int: String] = [:]
        /// The promised items the guest said it will not name.
        var unnamed: Set<Int> = []
        /// What failed the whole drag's naming, first only.
        var failure: ClipboardDragNamingFailure?
    }

    private struct State: Sendable {
        var records: [UInt64: Record] = [:]
        var hasEnded = false
        /// Every waiting thread's wakeup, by waiter: any change runs them all,
        /// and each waiter re-reads its own drag.
        var wakeups: [UInt64: @Sendable () -> Void] = [:]
        var lastWaiter: UInt64 = 0
    }

    private let state = Locked(State())

    // MARK: - What the guest says, on the reader thread

    /// Starts tracking a drag the guest offered, with its promised items. A
    /// drag already tracked keeps its record, as the main actor keeps its
    /// first offer.
    func track(generation: UInt64, promised: [Int: Bool]) {
        state.withLock { state in
            guard !state.hasEnded, state.records[generation] == nil else { return }
            state.records[generation] = Record(promised: promised)
        }
    }

    /// The guest answered `STAGE_RESOLVING`: the button may be released.
    func acknowledged(generation: UInt64) {
        transition(generation) { record in
            guard case .requested = record.exchange else { return false }
            record.exchange = .acknowledged
            return true
        }
    }

    /// The guest sent one `DragNames`, naming the promised items it lists; an
    /// empty name says that item will not be named. An item keeps the first
    /// word it is given.
    func named(generation: UInt64, filenames: [UInt32: String]) {
        transition(generation) { record in
            var changed = false
            for (key, name) in filenames {
                let index = Int(key)
                guard let isDirectory = record.promised[index], record.names[index] == nil,
                    !record.unnamed.contains(index)
                else { continue }
                if name.isEmpty {
                    record.unnamed.insert(index)
                } else {
                    record.names[index] = ClipboardDraggedItem.safeFilename(name, isDirectory: isDirectory)
                }
                changed = true
            }
            return changed
        }
    }

    /// The drag's items can no longer be named, for `failure`.
    func failed(generation: UInt64, _ failure: ClipboardDragNamingFailure) {
        transition(generation) { record in
            guard record.failure == nil else { return false }
            record.failure = failure
            return true
        }
    }

    // MARK: - What the owner decides, on any thread

    /// Forgets a drag that is retired, failing every ask still waiting on it.
    func retire(generation: UInt64) {
        let wakeups = state.withLock { state -> [@Sendable () -> Void] in
            guard state.records.removeValue(forKey: generation) != nil else { return [] }
            return Array(state.wakeups.values)
        }
        for wake in wakeups { wake() }
    }

    /// Forgets every drag because the connection is over, failing every ask
    /// still waiting and every one made from now on.
    func endSession() {
        let wakeups = state.withLock { state -> [@Sendable () -> Void] in
            state.hasEnded = true
            state.records = [:]
            return Array(state.wakeups.values)
        }
        for wake in wakeups { wake() }
    }

    // MARK: - Asking

    /// Starts naming `generation`'s promised items without waiting for any
    /// name, holding the calling thread until the button is released, the
    /// naming fails, or `deadline` passes.
    ///
    /// The drag's first ask runs the exchange: `send` puts `DragResolve` on the
    /// wire, reporting whether it went out, and once the guest answers
    /// `STAGE_RESOLVING`, `releasingGuestButton` runs on the calling thread.
    /// Any later ask, and a drag with no promised items, returns at once.
    ///
    /// The hold parks the calling thread on every thread, the main thread at
    /// the run loop's base included, and is bounded by `deadline`. It never
    /// runs the event loop, so nothing — a destination's own ask among it —
    /// runs inside the take that asked while it waits mid-transition. That
    /// park is the one exception to ``LazyPullCoordinator``'s "the main thread
    /// is never parked", which is written for byte transfers: AppKit asks a
    /// promise for its name synchronously and offers no asynchronous form, and
    /// the guest's answer is measured in milliseconds —
    /// `NSFilePromiseReceiver.fileNames` was filled 4–16 ms after
    /// `receivePromisedFiles` began, for Photos and Safari promises in a macOS
    /// 26.6.2 guest.
    ///
    /// - Returns: `nil` once the exchange is under way, or what failed the
    ///   drag's naming.
    func begin(
        generation: UInt64, deadline: DispatchTime, send: () -> Bool,
        releasingGuestButton: () -> Void
    ) -> ClipboardDragNamingFailure? {
        enum Start {
            case underWay
            case initiate
            case failed(ClipboardDragNamingFailure)
        }
        let start = state.withLock { state -> Start in
            if let failure = Self.dragFailure(state, generation: generation) { return .failed(failure) }
            guard var record = state.records[generation], !record.promised.isEmpty,
                case .idle = record.exchange
            else { return .underWay }
            record.exchange = .requested
            state.records[generation] = record
            return .initiate
        }
        switch start {
        case .underWay: return nil
        case .failed(let failure): return failure
        case .initiate: break
        }
        guard send() else {
            failed(generation: generation, .sessionEnded)
            return dragFailure(generation: generation) ?? .sessionEnded
        }
        enum Answer {
            case acknowledged
            case failed(ClipboardDragNamingFailure)
        }
        let answer = hold(deadline: deadline) { () -> Answer? in
            self.state.withLock { state in
                if let failure = Self.dragFailure(state, generation: generation) {
                    return .failed(failure)
                }
                guard case .acknowledged = state.records[generation]?.exchange else { return nil }
                return .acknowledged
            }
        }
        switch answer {
        case nil:
            failed(generation: generation, .timedOut)
            return dragFailure(generation: generation) ?? .timedOut
        case .failed(let failure)?:
            return failure
        case .acknowledged?:
            releasingGuestButton()
            return nil
        }
    }

    /// Names promised item `repIndex` of `generation`, holding the calling
    /// thread — parked, as ``begin(generation:deadline:send:releasingGuestButton:)``
    /// holds it — until the guest names it, says it will not, the drag's
    /// naming fails, or `deadline` passes.
    ///
    /// The drag's first ask starts the exchange as `begin` does; every ask
    /// then waits for its own item's `DragNames`. An item settled already is
    /// answered at once. `deadline` passing fails the whole drag.
    func resolveName(
        generation: UInt64, repIndex: Int, deadline: DispatchTime, send: () -> Bool,
        releasingGuestButton: () -> Void
    ) -> Result<String, ClipboardDragNamingFailure> {
        if let settled = settledName(generation: generation, repIndex: repIndex) { return settled }
        if let failure = begin(
            generation: generation, deadline: deadline, send: send,
            releasingGuestButton: releasingGuestButton)
        {
            return settledName(generation: generation, repIndex: repIndex) ?? .failure(failure)
        }
        let waited = hold(deadline: deadline) {
            self.settledName(generation: generation, repIndex: repIndex)
        }
        if let waited { return waited }
        failed(generation: generation, .timedOut)
        return settledName(generation: generation, repIndex: repIndex) ?? .failure(.timedOut)
    }

    // MARK: - Private

    /// Holds the calling thread, parked, until `resolved` returns a value or
    /// `deadline` passes, woken by every change to any drag.
    private func hold<Value>(
        deadline: DispatchTime, until resolved: @Sendable () -> Value?
    ) -> Value? {
        let semaphore = DispatchSemaphore(value: 0)
        let waiter = state.withLock { state -> UInt64 in
            state.lastWaiter &+= 1
            state.wakeups[state.lastWaiter] = { semaphore.signal() }
            return state.lastWaiter
        }
        defer { _ = state.withLock { $0.wakeups.removeValue(forKey: waiter) } }
        return ThreadHold.hold(
            eventLoop: nil, semaphore: semaphore, deadline: deadline, until: resolved)
    }

    /// Applies `change` to `generation`'s record, waking every waiter when it
    /// reports a change.
    private func transition(_ generation: UInt64, _ change: (inout Record) -> Bool) {
        let wakeups = state.withLock { state -> [@Sendable () -> Void] in
            guard var record = state.records[generation], change(&record) else { return [] }
            state.records[generation] = record
            return Array(state.wakeups.values)
        }
        for wake in wakeups { wake() }
    }

    private func dragFailure(generation: UInt64) -> ClipboardDragNamingFailure? {
        state.withLock { Self.dragFailure($0, generation: generation) }
    }

    /// How item `repIndex` of `generation` settled, or `nil` while it can
    /// still be named.
    private func settledName(
        generation: UInt64, repIndex: Int
    ) -> Result<String, ClipboardDragNamingFailure>? {
        state.withLock { state in
            guard !state.hasEnded else { return .failure(.sessionEnded) }
            guard let record = state.records[generation] else { return .failure(.dragNotLive) }
            guard record.promised[repIndex] != nil else { return .failure(.unnamed) }
            if let name = record.names[repIndex] { return .success(name) }
            if record.unnamed.contains(repIndex) { return .failure(.unnamed) }
            return record.failure.map { .failure($0) }
        }
    }

    /// What failed `generation`'s whole naming, or `nil` while it can go on.
    private static func dragFailure(
        _ state: State, generation: UInt64
    ) -> ClipboardDragNamingFailure? {
        guard !state.hasEnded else { return .sessionEnded }
        guard let record = state.records[generation] else { return .dragNotLive }
        return record.failure
    }
}
