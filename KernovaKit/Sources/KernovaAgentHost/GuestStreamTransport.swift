import KernovaAgentRuntime
import KernovaSynchronization

/// Where a VM's agent connections come from: one listener, its live streams, and the cap on them.
public protocol GuestStreamTransport: Sendable {
    /// Begins accepting. Each accepted stream reaches `accept` on the thread that accepted it, and at most
    /// `GuestStreamAcceptor.connectionLimit` are live at once.
    func start(accept: @escaping @Sendable (any ByteStream) -> Void)
    /// Stops accepting and shuts down every live stream. Idempotent.
    func stop()
    /// The streams accepted whose descriptors are not yet released.
    var liveConnectionCount: Int { get }
}

/// The admission half of a `GuestStreamTransport`: the cap, the live streams, and the hand-off to `accept`.
///
/// A slot is taken before the connection is touched and given back only when its stream releases its
/// descriptor, so the cap counts exactly the connections that hold memory (spec §9.7.1).
public final class GuestStreamAcceptor: GuestStreamTransport {
    /// The most agent connections one VM holds at once: one system peer plus session peers.
    public static let connectionLimit = 8

    private enum Slot: Sendable {
        /// Taken; its stream is being built.
        case reserved
        case open(any ByteStream)
    }

    private struct State: Sendable {
        var accept: (@Sendable (any ByteStream) -> Void)?
        var stopped = false
        var slots: [UInt64: Slot] = [:]
        var nextToken: UInt64 = 0
    }

    private let limit: Int
    private let state = Locked(State())

    /// An acceptor admitting at most `limit` live connections.
    public init(limit: Int = GuestStreamAcceptor.connectionLimit) {
        self.limit = limit
    }

    /// Hands each connection `offer(_:)` accepts to `accept`, on the offering thread; no-op once stopped.
    public func start(accept: @escaping @Sendable (any ByteStream) -> Void) {
        state.withLock { state in
            guard !state.stopped else { return }
            state.accept = accept
        }
    }

    /// Refuses every later offer and shuts down every live stream; their slots free as they release.
    public func stop() {
        let streams = state.withLock { state -> [any ByteStream] in
            state.stopped = true
            state.accept = nil
            return state.slots.values.compactMap { slot in
                if case .open(let stream) = slot { return stream }
                return nil
            }
        }
        for stream in streams { stream.shutdown() }
    }

    /// The slots taken: streams being built or not yet released.
    public var liveConnectionCount: Int { state.withLock { $0.slots.count } }

    /// Decides one connection a guest opened, answering whether it was accepted.
    ///
    /// `open` runs only when a slot is free and the acceptor is started and not stopped; it builds the
    /// stream over the connection, passing it `released` to call once the stream lets its descriptor go,
    /// or answers `nil` when it cannot. A refusal at the cap touches nothing.
    public func offer(_ open: (_ released: @escaping @Sendable () -> Void) -> (any ByteStream)?) -> Bool {
        let reservation = state.withLock { state -> (token: UInt64, accept: @Sendable (any ByteStream) -> Void)? in
            guard !state.stopped, let accept = state.accept, state.slots.count < limit else { return nil }
            state.nextToken += 1
            state.slots[state.nextToken] = .reserved
            return (state.nextToken, accept)
        }
        guard let reservation else { return false }
        let token = reservation.token
        guard let stream = open({ [self] in release(token) }) else {
            release(token)
            return false
        }
        let admitted = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.slots[token] = .open(stream)
            return true
        }
        guard admitted else {
            // Stopped while the stream was built: it never reached `accept`, and shutting it down releases
            // its slot.
            stream.shutdown()
            return false
        }
        reservation.accept(stream)
        return true
    }

    private func release(_ token: UInt64) {
        state.withLock { _ = $0.slots.removeValue(forKey: token) }
    }
}
