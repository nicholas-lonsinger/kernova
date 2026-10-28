import KernovaAgentRuntime
import KernovaLogging
import KernovaSynchronization

/// Where a VM's agent connections come from: one listener, which hands every connection a guest opens to
/// the hub's acceptor.
public protocol GuestStreamTransport: Sendable {
    /// Begins listening. Every connection a guest opens goes to `acceptor.offer(_:)`, which decides it
    /// before anything reads it.
    func start(admitting acceptor: GuestStreamAcceptor)
    /// Stops listening. The streams already accepted are the acceptor's.
    func stop()
}

/// The hub's admission of one transport's connections: the cap, the live streams, and the hand-off to
/// the hub.
///
/// A slot is taken before the connection is touched and given back only when its stream releases its
/// descriptor, so the cap counts exactly the connections that hold memory (spec §9.7.1). A refusal at the
/// cap is logged once per run of refusals, when the run starts and when a slot next frees, so a guest
/// redialing in a loop costs the host log two records.
public final class GuestStreamAcceptor: Sendable {
    /// The most agent connections one VM holds at once: one system peer plus session peers.
    public static let connectionLimit = 8

    private enum Slot: Sendable {
        /// Taken; its stream is being built.
        case reserved
        case open(any ByteStream)
    }

    private struct State: Sendable {
        var stopped = false
        var slots: [UInt64: Slot] = [:]
        var nextToken: UInt64 = 0
        /// Connections refused at the cap since a slot last freed; 0 while none is.
        var refusedInRun = 0
    }

    private let limit: Int
    private let logger: KernovaLogger
    private let accept: @Sendable (any ByteStream) -> Void
    private let state = Locked(State())

    /// An acceptor handing each connection it admits to `accept`, at most `limit` live at once.
    package init(
        limit: Int = GuestStreamAcceptor.connectionLimit, logger: KernovaLogger,
        accept: @escaping @Sendable (any ByteStream) -> Void
    ) {
        self.limit = limit
        self.logger = logger
        self.accept = accept
    }

    /// Refuses every later offer and shuts down every live stream; their slots free as they release.
    public func stop() {
        let streams = state.withLock { state -> [any ByteStream] in
            state.stopped = true
            return state.slots.values.compactMap { slot in
                if case .open(let stream) = slot { return stream }
                return nil
            }
        }
        for stream in streams { stream.shutdown() }
    }

    /// The slots taken: streams being built or not yet released.
    public var liveConnectionCount: Int { state.withLock { $0.slots.count } }

    /// Decides one connection a guest opened, answering whether it was accepted, on the thread the
    /// transport accepts on.
    ///
    /// `open` runs only when a slot is free and the acceptor is not stopped; it builds the stream over the
    /// connection, passing it `released` to call once the stream lets its descriptor go, or answers `nil`
    /// when it cannot. A refusal at the cap touches nothing.
    public func offer(_ open: (_ released: @escaping @Sendable () -> Void) -> (any ByteStream)?) -> Bool {
        enum Decision {
            case reserved(UInt64)
            case stopped
            case full(startsRun: Bool)
        }
        let decision = state.withLock { state -> Decision in
            guard !state.stopped else { return .stopped }
            guard state.slots.count < limit else {
                state.refusedInRun += 1
                return .full(startsRun: state.refusedInRun == 1)
            }
            state.nextToken += 1
            state.slots[state.nextToken] = .reserved
            return .reserved(state.nextToken)
        }
        let token: UInt64
        switch decision {
        case .stopped:
            return false
        case .full(let startsRun):
            if startsRun {
                logger.log(
                    .notice,
                    "Refusing agent connections: \(self.limit, privacy: .public) are live, the most one VM holds")
            }
            return false
        case .reserved(let reserved):
            token = reserved
        }
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
            // Stopped while the stream was built: it never reaches `accept`, and shutting it down releases
            // its slot.
            stream.shutdown()
            return false
        }
        accept(stream)
        return true
    }

    private func release(_ token: UInt64) {
        let refused = state.withLock { state -> Int in
            guard state.slots.removeValue(forKey: token) != nil else { return 0 }
            defer { state.refusedInRun = 0 }
            return state.refusedInRun
        }
        if refused > 0 {
            logger.log(
                .notice,
                "An agent connection slot is free again, after \(refused, privacy: .public) connection(s) were refused"
            )
        }
    }
}
