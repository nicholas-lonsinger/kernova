#if os(Linux)
// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch does not.
@preconcurrency import Dispatch
import KernovaAgentCore
import KernovaDBus
import KernovaSynchronization

/// A peer's place in the guest's sessions, read from logind and followed as it changes.
///
/// Every Linux peer runs as a systemd service — the session peer in `user@UID.service`, the system peer as
/// a system unit — so neither belongs to a logind session, and `GetSessionByPID` fails for both
/// (docs/research/2026-10-28-linux-logind-polkit-user-service-and-inhibitors.md, finding 4). The session
/// peer follows its user's `Display` session instead, and the system peer seat0's `ActiveSession`.
///
/// Each follows two objects: a fixed one — the user, or seat0 — and the session it names now. Any change
/// either signals rereads the whole state, so no sequence of signals can leave a stale value behind.
public final class LogindPeerStateWatcher: Sendable {
    private let logind: Logind
    private let queue: DispatchQueue
    private let source: Source
    private let deliver: @Sendable (Result<PeerSessionState?, LogindError>) -> Void
    private let state = Locked(State())

    private enum Source: Sendable {
        /// The session peer's user.
        case user(DBusObjectPath)
        /// The system peer's seat0.
        case seat(DBusObjectPath)
        /// A logind with no seat0, which has nothing to follow.
        case noSeat
    }

    private struct State: Sendable {
        var fixed: DBusSubscription?
        /// The session the last read named, and its subscription.
        var session: (path: DBusObjectPath, subscription: DBusSubscription)?
        /// What was delivered last; nil before the first delivery.
        var delivered: PeerSessionState??
        var refreshQueued = false
        var isCancelled = false
    }

    /// Follows the session peer's state for `uid`: its user's display session's `Id`, the console ON
    /// while that session holds the screen (`ownsConsole`), and the user's login name; nil while logind
    /// elects no display session for the user, as for a lingering user with no session at all.
    ///
    /// Delivers the first state, then each that differs from the last, on `queue`, where every read runs
    /// — never on the connection's reader thread. A failed read delivers its error and keeps watching:
    /// the next change rereads. Throws when logind does not know the user or refuses the subscription.
    public static func sessionPeer(
        _ logind: Logind, uid: UInt32, on queue: DispatchQueue,
        _ deliver: @escaping @Sendable (Result<PeerSessionState?, LogindError>) -> Void
    ) throws(LogindError) -> LogindPeerStateWatcher {
        let watcher = LogindPeerStateWatcher(logind, .user(try logind.user(uid)), queue, deliver)
        try watcher.start()
        return watcher
    }

    /// Follows the system peer's state: the console ON, naming the session, while seat0's foreground
    /// session holds the screen; OFF at the greeter, and OFF when seat0 has no foreground session, as on a
    /// headless guest. logind always has seat0; one that answers it has none reads OFF for good. It is
    /// never UNKNOWN, which would make the host pass over every session peer, and never nil.
    ///
    /// Delivers as `sessionPeer(_:uid:on:_:)` does.
    public static func systemPeer(
        _ logind: Logind, on queue: DispatchQueue,
        _ deliver: @escaping @Sendable (Result<PeerSessionState?, LogindError>) -> Void
    ) throws(LogindError) -> LogindPeerStateWatcher {
        let source: Source
        do throws(LogindError) {
            source = .seat(try logind.seat("seat0"))
        } catch .call(.remote(let error)) where error.name == noSuchSeat {
            source = .noSeat
        }
        let watcher = LogindPeerStateWatcher(logind, source, queue, deliver)
        try watcher.start()
        return watcher
    }

    private init(
        _ logind: Logind, _ source: Source, _ queue: DispatchQueue,
        _ deliver: @escaping @Sendable (Result<PeerSessionState?, LogindError>) -> Void
    ) {
        self.logind = logind
        self.source = source
        self.queue = queue
        self.deliver = deliver
    }

    /// Stops following: nothing is delivered once it returns on `queue`, or once a delivery in flight
    /// there finishes.
    public func cancel() {
        let subscriptions = state.withLock { state in
            defer {
                state.isCancelled = true
                state.fixed = nil
                state.session = nil
            }
            return [state.fixed, state.session?.subscription].compactMap { $0 }
        }
        for subscription in subscriptions { subscription.cancel() }
    }

    /// Subscribes to the fixed object, before the first read, so no change falls between the two.
    private func start() throws(LogindError) {
        let fixed: DBusSubscription?
        switch source {
        case .user(let user): fixed = try logind.observeUser(user) { [weak self] _ in self?.queueRefresh() }
        case .seat(let seat): fixed = try logind.observeSeat(seat) { [weak self] _ in self?.queueRefresh() }
        case .noSeat: fixed = nil
        }
        state.withLock { $0.fixed = fixed }
        queueRefresh()
    }

    /// Queues one reread, unless one is queued already and has not yet started.
    private func queueRefresh() {
        let queued = state.withLock { state in
            defer { state.refreshQueued = true }
            return state.refreshQueued
        }
        if !queued { queue.async { [self] in refresh() } }
    }

    /// Rereads until the session the read names is the one subscribed to, then delivers what it read
    /// when that differs from the last delivery.
    private func refresh() {
        dispatchPrecondition(condition: .onQueue(queue))
        state.withLock { $0.refreshQueued = false }
        do throws(LogindError) {
            while true {
                guard !state.withLock(\.isCancelled) else { return }
                let reading = try read()
                let watched = state.withLock { $0.session?.path }
                if reading.session == watched { return deliverIfChanged(.success(reading.state)) }
                try watch(reading.session)
            }
        } catch {
            deliverIfChanged(.failure(error))
        }
    }

    /// Moves the session subscription to `path`; the next read follows it.
    private func watch(_ path: DBusObjectPath?) throws(LogindError) {
        let old = state.withLock { state in
            defer { state.session = nil }
            return state.session?.subscription
        }
        old?.cancel()
        guard let path else { return }
        let subscription = try logind.observeSession(path) { [weak self] _ in self?.queueRefresh() }
        let cancelled = state.withLock { state in
            if !state.isCancelled { state.session = (path, subscription) }
            return state.isCancelled
        }
        if cancelled { subscription.cancel() }
    }

    private func deliverIfChanged(_ result: Result<PeerSessionState?, LogindError>) {
        let changed = state.withLock { state -> Bool in
            guard !state.isCancelled else { return false }
            guard case .success(let peerState) = result else { return true }
            guard state.delivered != .some(peerState) else { return false }
            state.delivered = .some(peerState)
            return true
        }
        if changed { deliver(result) }
    }

    /// The state now, and the session it names.
    private func read() throws(LogindError) -> (state: PeerSessionState?, session: DBusObjectPath?) {
        switch source {
        case .user(let user):
            guard let display = try logind.displaySession(ofUser: user) else { return (nil, nil) }
            let properties = try logind.sessionProperties(display.path)
            let peerState = PeerSessionState(
                console: properties.ownsConsole ? .on : .off, sessionID: properties.id,
                userName: try logind.userName(user))
            return (peerState, display.path)
        case .seat(let seat):
            guard let active = try logind.activeSession(onSeat: seat) else {
                return (PeerSessionState(console: .off), nil)
            }
            let properties = try logind.sessionProperties(active.path)
            guard properties.ownsConsole else { return (PeerSessionState(console: .off), active.path) }
            return (PeerSessionState(console: .on, consoleSessionID: properties.id), active.path)
        case .noSeat:
            return (PeerSessionState(console: .off), nil)
        }
    }

    private static let noSuchSeat = "org.freedesktop.login1.NoSuchSeat"
}

extension LogindSessionProperties {
    /// Whether the session holds the guest's screen: on a seat, in the foreground there, and a user's
    /// rather than a greeter's or a lock screen's. A seatless session, which logind reports as always
    /// active, holds no screen.
    var ownsConsole: Bool {
        seat != nil && active && sessionClass == .user
    }
}
#endif
