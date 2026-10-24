import Foundation
import KernovaSynchronization

/// The host's naming of the promised items in the guest's drags: asking for
/// them (`DragResolve`), the guest's answer (`STAGE_RESOLVING` or
/// `STAGE_FAILED`), and the names they took (`DragNames`).
///
/// Every reply is recorded here on the session's reader thread, before any hop
/// to the main actor: the thread waiting for the names can be the main thread
/// itself, held inside the Mac drag's tracking loop, which runs nothing queued
/// to main until it returns.
///
/// A drag's first terminal — its names, or a failure — stands until the drag
/// is retired, so every later ask is answered at once with the same result.
final class ClipboardDragNaming: Sendable {
    /// Where one drag's naming is.
    private enum Phase: Sendable {
        /// Nothing has asked.
        case idle
        /// `DragResolve` is away; the guest has not answered.
        case requested
        /// The guest answered `STAGE_RESOLVING`; its names have not arrived.
        case acknowledged
        case named([Int: String])
        case failed(ClipboardDragNamingFailure)

        var isTerminal: Bool {
            switch self {
            case .named, .failed: true
            case .idle, .requested, .acknowledged: false
            }
        }
    }

    /// One drag the guest offered, from its `DragOffer` to its retirement.
    private struct Record: Sendable {
        /// Each promised item's index, and whether it is a directory.
        let promised: [Int: Bool]
        var phase: Phase = .idle
    }

    private struct State: Sendable {
        var records: [UInt64: Record] = [:]
        var hasEnded = false
        /// Every waiting thread's wakeup, by waiter: any change runs them all,
        /// and each waiter re-reads its own drag.
        var wakeups: [UInt64: @Sendable () -> Void] = [:]
        var lastWaiter: UInt64 = 0
    }

    /// What a waiting thread sees of its drag.
    private enum Observation: Sendable {
        case requested
        case acknowledged
        case settled(Result<[Int: String], ClipboardDragNamingFailure>)
    }

    private let state = Locked(State())

    /// Vends the event-loop wait a resolve on the calling thread runs, or `nil`
    /// where it parks.
    private let eventLoopWait: Locked<@Sendable () -> NestedEventLoopWait?>

    init(
        eventLoopWait: @escaping @Sendable () -> NestedEventLoopWait? = {
            NestedEventLoopWait.current()
        }
    ) {
        self.eventLoopWait = Locked(eventLoopWait)
    }

    #if DEBUG
    /// Test seam: replaces where a resolve takes its wait from — `{ nil }`
    /// parks even the main thread, as inside a tracking loop.
    func setEventLoopWaitForTesting(_ vend: @escaping @Sendable () -> NestedEventLoopWait?) {
        eventLoopWait.withLock { $0 = vend }
    }
    #endif

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
        transition(generation) { phase in
            guard case .requested = phase else { return false }
            phase = .acknowledged
            return true
        }
    }

    /// The guest sent the names its promised items took, as `DragNames`
    /// carries them.
    func named(generation: UInt64, filenames: [UInt32: String]) {
        transition(generation) { phase, promised in
            guard !phase.isTerminal else { return false }
            phase = .named(Self.sanitizedNames(filenames, promised: promised))
            return true
        }
    }

    /// The drag can no longer be named, for `failure`.
    func failed(generation: UInt64, _ failure: ClipboardDragNamingFailure) {
        transition(generation) { phase in
            guard !phase.isTerminal else { return false }
            phase = .failed(failure)
            return true
        }
    }

    // MARK: - What the owner decides, on any thread

    /// Forgets a drag that is retired, failing a resolve still waiting on it.
    func retire(generation: UInt64) {
        let wakeups = state.withLock { state -> [@Sendable () -> Void] in
            guard state.records.removeValue(forKey: generation) != nil else { return [] }
            return Array(state.wakeups.values)
        }
        for wake in wakeups { wake() }
    }

    /// Forgets every drag because the connection is over, failing every
    /// resolve still waiting and every one asked from now on.
    func endSession() {
        let wakeups = state.withLock { state -> [@Sendable () -> Void] in
            state.hasEnded = true
            state.records = [:]
            return Array(state.wakeups.values)
        }
        for wake in wakeups { wake() }
    }

    // MARK: - Reading the names

    /// The names `generation`'s promised items took, or `nil` until they have
    /// arrived.
    func names(generation: UInt64) -> [Int: String]? {
        state.withLock { state in
            guard case .named(let names) = state.records[generation]?.phase else { return nil }
            return names
        }
    }

    /// Names `generation`'s promised items, holding the calling thread until
    /// the guest names them, fails, or `deadline` passes.
    ///
    /// The first caller runs the exchange: `send` puts `DragResolve` on the
    /// wire, reporting whether it went out, and once the guest answers
    /// `STAGE_RESOLVING`, `releasingGuestButton` runs on the calling thread. A
    /// caller arriving while that is in flight joins it, waiting to its own
    /// deadline. A drag with no promised items is named at once, with nothing.
    ///
    /// The hold runs the event loop on the main run loop's base and parks
    /// anywhere else — the main thread inside a tracking loop included. That
    /// park is the one exception to ``LazyPullCoordinator``'s "the main thread
    /// is never parked", which is written for byte transfers: AppKit asks a
    /// promise for its name synchronously and offers no asynchronous form, the
    /// park is bounded by `deadline`, and the guest's answer measured in
    /// milliseconds — `NSFilePromiseReceiver.fileNames` was filled 4–16 ms
    /// after `receivePromisedFiles` began, for Photos and Safari promises in a
    /// macOS 26.6.2 guest.
    func resolve(
        generation: UInt64, deadline: DispatchTime, send: () -> Bool,
        releasingGuestButton: () -> Void
    ) -> Result<[Int: String], ClipboardDragNamingFailure> {
        enum Start {
            case settled(Result<[Int: String], ClipboardDragNamingFailure>)
            case initiate
            case join
        }
        let start = state.withLock { state -> Start in
            if let settled = Self.settled(state, generation: generation) {
                return .settled(settled)
            }
            guard var record = state.records[generation], case .idle = record.phase else {
                return .join
            }
            guard !record.promised.isEmpty else {
                record.phase = .named([:])
                state.records[generation] = record
                return .settled(.success([:]))
            }
            record.phase = .requested
            state.records[generation] = record
            return .initiate
        }
        if case .settled(let result) = start { return result }

        let semaphore = DispatchSemaphore(value: 0)
        let eventLoop = eventLoopWait.withLock { $0 }()
        let waiter = state.withLock { state -> UInt64 in
            state.lastWaiter &+= 1
            state.wakeups[state.lastWaiter] = {
                semaphore.signal()
                eventLoop?.wake()
            }
            return state.lastWaiter
        }
        defer { _ = state.withLock { $0.wakeups.removeValue(forKey: waiter) } }

        if case .initiate = start {
            guard send() else {
                failed(generation: generation, .sessionEnded)
                return settledResult(generation: generation)
            }
            let answer = ThreadHold.hold(
                eventLoop: eventLoop, semaphore: semaphore, deadline: deadline
            ) { () -> Observation? in
                let observation = self.observe(generation: generation)
                if case .requested = observation { return nil }
                return observation
            }
            switch answer {
            case nil: return timeOut(generation: generation)
            case .settled(let result)?: return result
            case .acknowledged?: releasingGuestButton()
            case .requested?: break
            }
        }
        let settled = ThreadHold.hold(
            eventLoop: eventLoop, semaphore: semaphore, deadline: deadline
        ) { () -> Result<[Int: String], ClipboardDragNamingFailure>? in
            guard case .settled(let result) = self.observe(generation: generation) else {
                return nil
            }
            return result
        }
        return settled ?? timeOut(generation: generation)
    }

    // MARK: - Private

    /// `names` reduced to safe path components, keeping only the promised
    /// items' and dropping an empty name, which names nothing.
    static func sanitizedNames(
        _ names: [UInt32: String], promised: [Int: Bool]
    ) -> [Int: String] {
        var sanitized: [Int: String] = [:]
        for (key, name) in names where !name.isEmpty {
            let index = Int(key)
            guard let isDirectory = promised[index] else { continue }
            sanitized[index] = ClipboardDraggedItem.safeFilename(name, isDirectory: isDirectory)
        }
        return sanitized
    }

    /// Applies `change` to `generation`'s phase, waking every waiter when it
    /// reports a change.
    private func transition(
        _ generation: UInt64, _ change: (inout Phase, [Int: Bool]) -> Bool
    ) {
        let wakeups = state.withLock { state -> [@Sendable () -> Void] in
            guard var record = state.records[generation],
                change(&record.phase, record.promised)
            else { return [] }
            state.records[generation] = record
            return Array(state.wakeups.values)
        }
        for wake in wakeups { wake() }
    }

    private func transition(_ generation: UInt64, _ change: (inout Phase) -> Bool) {
        transition(generation) { phase, _ in change(&phase) }
    }

    /// Records the deadline passing as `generation`'s failure, unless it has
    /// already settled, and returns how it settled.
    private func timeOut(
        generation: UInt64
    ) -> Result<[Int: String], ClipboardDragNamingFailure> {
        failed(generation: generation, .timedOut)
        return settledResult(generation: generation)
    }

    private func settledResult(
        generation: UInt64
    ) -> Result<[Int: String], ClipboardDragNamingFailure> {
        state.withLock { Self.settled($0, generation: generation) } ?? .failure(.timedOut)
    }

    private func observe(generation: UInt64) -> Observation {
        state.withLock { state in
            if let settled = Self.settled(state, generation: generation) {
                return .settled(settled)
            }
            if case .acknowledged = state.records[generation]?.phase { return .acknowledged }
            return .requested
        }
    }

    /// How `generation`'s naming settled, or `nil` while it is still open.
    private static func settled(
        _ state: State, generation: UInt64
    ) -> Result<[Int: String], ClipboardDragNamingFailure>? {
        guard !state.hasEnded else { return .failure(.sessionEnded) }
        guard let record = state.records[generation] else { return .failure(.dragNotLive) }
        switch record.phase {
        case .named(let names): return .success(names)
        case .failed(let failure): return .failure(failure)
        case .idle, .requested, .acknowledged: return nil
        }
    }
}
