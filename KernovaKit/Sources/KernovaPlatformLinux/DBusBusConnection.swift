#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaDBus

/// A connection to a message bus, driving a `DBusConnection` over a
/// `DBusTransport` from two threads of its own: one blocks in reads and
/// handles what they complete, one blocks in writes.
///
/// Signal handlers and the method-call handler run on the reader thread, one
/// message at a time in arrival order; one that blocks stalls every later
/// message, so none may make a blocking call on this connection.
///
/// The connection ends on `close()`, on deinit, or when the bus or transport
/// fails it; every call then waiting throws `DBusCallError.disconnected`.
public final class DBusBusConnection: Sendable {
    /// How long a call waits for its reply by default: the reference
    /// implementation's default reply timeout.
    public static let defaultTimeout: Duration = .seconds(25)

    /// This connection's unique name on the bus.
    public let uniqueName: String

    private let engine: DBusConnectionEngine

    /// The well-known buses.
    public enum Bus: Sendable, Hashable {
        /// `DBUS_SYSTEM_BUS_ADDRESS`, else `/run/dbus/system_bus_socket`.
        case system
        /// `DBUS_SESSION_BUS_ADDRESS`.
        case session

        /// The bus's address from the environment, or its default.
        public func address() throws(DBusConnectError) -> String {
            switch self {
            case .system:
                return Self.environment("DBUS_SYSTEM_BUS_ADDRESS") ?? "unix:path=/run/dbus/system_bus_socket"
            case .session:
                guard let address = Self.environment("DBUS_SESSION_BUS_ADDRESS") else {
                    throw .noSessionBusAddress
                }
                return address
            }
        }

        private static func environment(_ name: String) -> String? {
            getenv(name).map { String(cString: $0) }
        }
    }

    /// Connects to `bus`.
    ///
    /// `onMethodCall` answers each method call to this connection with the
    /// reply to send, or nil to send none. Without one, every call gets
    /// `org.freedesktop.DBus.Error.UnknownMethod`. A reply to a call sent with
    /// NO_REPLY_EXPECTED is dropped.
    public convenience init(
        bus: Bus, onMethodCall: (@Sendable (DBusReceivedMessage) -> DBusMessage?)? = nil
    ) throws(DBusConnectError) {
        try self.init(address: try bus.address(), onMethodCall: onMethodCall)
    }

    /// Connects to the first address in `address` whose socket accepts the
    /// connection, then authenticates and says `Hello` over it, `onMethodCall`
    /// as `init(bus:onMethodCall:)` takes it.
    public convenience init(
        address: String, onMethodCall: (@Sendable (DBusReceivedMessage) -> DBusMessage?)? = nil
    ) throws(DBusConnectError) {
        let addresses: [DBusAddress]
        do throws(DBusAddressError) {
            addresses = try DBusAddress.parse(address)
        } catch {
            throw .invalidAddress(error)
        }
        var transport: UnixSocketTransport?
        var lastError: DBusTransportError?
        for socket in addresses.compactMap(\.unixSocket) where transport == nil {
            do throws(DBusTransportError) {
                transport = try UnixSocketTransport(connectingTo: socket)
            } catch {
                lastError = error
            }
        }
        guard let transport else {
            throw lastError.map { .transport($0) } ?? .noConnectableAddress(address)
        }
        try self.init(transport: transport, uid: getuid(), onMethodCall: onMethodCall)
    }

    /// Authenticates as `uid` and says `Hello` over `transport`, returning
    /// once the bus answers, `onMethodCall` as `init(bus:onMethodCall:)` takes
    /// it.
    public init(
        transport: any DBusTransport, uid: UInt32,
        onMethodCall: (@Sendable (DBusReceivedMessage) -> DBusMessage?)? = nil
    ) throws(DBusConnectError) {
        let engine = DBusConnectionEngine(transport: transport, uid: uid, onMethodCall: onMethodCall)
        do throws(DBusConnectError) {
            try engine.start()
        } catch {
            engine.close()
            throw error
        }
        do throws(DBusCallError) {
            uniqueName = try engine.waitUntilReady(timeout: Self.defaultTimeout)
        } catch {
            engine.close()
            throw .handshake(error)
        }
        self.engine = engine
    }

    deinit {
        engine.close()
    }

    /// Sends `call` and blocks until its reply arrives, returning a
    /// METHOD_RETURN and throwing an ERROR as `DBusCallError.remote`.
    ///
    /// `call` is a METHOD_CALL awaiting a reply. Calling this from a handler
    /// the connection runs traps: the reply could never be read.
    public func call(_ call: DBusMessage, timeout: Duration = defaultTimeout) throws(DBusCallError)
        -> DBusReceivedMessage
    {
        precondition(call.header.kind == .methodCall && !call.header.flags.contains(.noReplyExpected))
        return try engine.call(call, timeout: timeout)
    }

    /// Queues `message` to be written, awaiting no reply, and returns its
    /// serial.
    @discardableResult
    public func send(_ message: DBusMessage) throws(DBusCallError) -> UInt32 {
        try engine.send(message)
    }

    /// Registers `rule` with the bus, then calls `handler`, on the reader
    /// thread, for each message that matches it, until the subscription is
    /// cancelled.
    ///
    /// A rule naming a well-known sender matches only messages from the name's
    /// current owner, which the connection follows through `NameOwnerChanged`:
    /// a message bus sets every message's sender, so a peer cannot pose as the
    /// owner.
    public func subscribe(
        _ rule: DBusMatchRule, handler: @escaping @Sendable (DBusReceivedMessage) -> Void
    ) throws(DBusCallError) -> DBusSubscription {
        try engine.subscribe(rule, handler: handler)
    }

    /// Ends the connection. Once it returns no handler is running or called
    /// again, unless it is called from a handler, which then finishes.
    public func close() {
        engine.close()
    }
}

/// A match registered with `DBusBusConnection.subscribe(_:handler:)`.
public struct DBusSubscription: Sendable {
    fileprivate let engine: DBusConnectionEngine
    fileprivate let id: UInt64

    /// Stops calling the handler and removes the rule from the bus. Once it
    /// returns the handler is not running and is never called again — unless
    /// it is called from the handler itself, which then finishes. Calling it
    /// again does nothing.
    public func cancel() {
        engine.unsubscribe(id)
    }
}

/// Why a call returned no reply.
public enum DBusCallError: Error, Hashable, Sendable {
    /// The peer answered with an ERROR.
    case remote(DBusRemoteError)
    /// No reply arrived in time.
    case timedOut
    /// The connection ended.
    case disconnected(DBusDisconnection)
    /// The message to send broke the specification's rules.
    case invalidMessage(DBusProtocolError)
}

/// Why a connection ended.
public enum DBusDisconnection: Error, Hashable, Sendable {
    /// `close()` ended it.
    case closed
    /// The bus closed the stream.
    case endOfStream
    /// The transport failed.
    case transport(DBusTransportError)
    /// The bus sent what the protocol does not allow, or refused this side.
    case connection(DBusConnectionError)
}

/// Why connecting to a bus failed.
public enum DBusConnectError: Error, Hashable, Sendable {
    /// `DBUS_SESSION_BUS_ADDRESS` is not set.
    case noSessionBusAddress
    /// The address is not valid address syntax.
    case invalidAddress(DBusAddressError)
    /// No address names a Unix socket.
    case noConnectableAddress(String)
    /// The last socket tried refused the connection.
    case transport(DBusTransportError)
    /// Authentication or `Hello` failed.
    case handshake(DBusCallError)
    /// `pthread_create` failed with this error.
    case threadUnavailable(Int32)
}

/// The state both threads and every caller share, behind one condition.
private final class DBusConnectionEngine: @unchecked Sendable {
    private enum ReplySlot {
        case waiting
        case arrived(DBusReceivedMessage)
    }

    private struct Subscription {
        var rule: DBusMatchRule
        var handler: @Sendable (DBusReceivedMessage) -> Void
    }

    private struct State {
        var core: DBusConnection
        var uniqueName: String?
        var disconnection: DBusDisconnection?
        var replies: [UInt32: ReplySlot] = [:]
        var subscriptions: [UInt64: Subscription] = [:]
        var nextSubscriptionID: UInt64 = 1
        /// The tracked well-known names: each one's owner, and how many
        /// subscriptions name it.
        var owners: [String: (owner: String?, subscribers: Int)] = [:]
        /// `GetNameOwner` calls in flight, by serial.
        var ownerLookups: [UInt32: String] = [:]
        /// The handler the reader thread is running, while it runs: a
        /// subscription's, or the method-call handler's when nil.
        var delivery: (subscription: UInt64?, thread: pthread_t)?

        /// Whether the calling thread is running a handler, so a blocking call
        /// from it could never read its reply. The identity exists only while
        /// the handler runs, so no later thread given the same `pthread_t` can
        /// match it.
        var isDeliveryThread: Bool { delivery.map { isCurrentThread($0.thread) } ?? false }

        /// The unique name a rule's `sender` currently stands for.
        func owner(of sender: String?) -> String? {
            guard let sender else { return nil }
            guard Self.isTracked(sender) else { return sender }
            return owners[sender]?.owner
        }

        /// Whether `name` is well-known, other than the bus's own.
        static func isTracked(_ name: String) -> Bool {
            !name.hasPrefix(":") && name != DBusBus.name
        }
    }

    private let transport: any DBusTransport
    private let onMethodCall: (@Sendable (DBusReceivedMessage) -> DBusMessage?)?
    private let condition = Condition()
    /// Read and written only while `condition` is locked.
    private var state: State

    init(
        transport: any DBusTransport, uid: UInt32, onMethodCall: (@Sendable (DBusReceivedMessage) -> DBusMessage?)?
    ) {
        self.transport = transport
        self.onMethodCall = onMethodCall
        state = State(core: DBusConnection(uid: uid))
    }

    /// Starts the reader and writer threads; a failure to start the writer
    /// leaves the reader for `close()` to end.
    func start() throws(DBusConnectError) {
        let reader = startThread { [self] in runReader() }
        guard reader == 0 else { throw .threadUnavailable(reader) }
        let writer = startThread { [self] in runWriter() }
        guard writer == 0 else { throw .threadUnavailable(writer) }
    }

    private func locked<Result, Failure: Error>(
        _ body: (inout State) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        return try body(&state)
    }

    func waitUntilReady(timeout: Duration) throws(DBusCallError) -> String {
        let deadline = Deadline(after: timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let name = state.uniqueName { return name }
            if let disconnection = state.disconnection { throw .disconnected(disconnection) }
            guard condition.wait(until: deadline) else {
                if let name = state.uniqueName { return name }
                throw .timedOut
            }
        }
    }

    func close() {
        disconnect(.closed)
    }

    /// Waits until no handler `isAwaited` picks is running, unless the caller
    /// is the handler.
    private func awaitDeliveries(_ isAwaited: (UInt64?) -> Bool) {
        condition.lock()
        defer { condition.unlock() }
        while let delivery = state.delivery, isAwaited(delivery.subscription), !state.isDeliveryThread {
            condition.wait()
        }
    }

    /// Calls subscription `id`'s handler with `signal`, if the subscription is
    /// still registered and the connection still open, recording the delivery
    /// for `awaitDeliveries(_:)` while it runs.
    private func deliver(_ signal: DBusReceivedMessage, to id: UInt64) {
        let handler = locked { state -> (@Sendable (DBusReceivedMessage) -> Void)? in
            guard state.disconnection == nil, let subscription = state.subscriptions[id] else { return nil }
            state.delivery = (id, pthread_self())
            return subscription.handler
        }
        guard let handler else { return }
        handler(signal)
        locked { $0.delivery = nil }
    }

    /// What the method-call handler answers `call` with, recorded as a
    /// delivery while it runs; nil when the connection has closed.
    private func answer(_ call: DBusReceivedMessage, with handler: (DBusReceivedMessage) -> DBusMessage?)
        -> DBusMessage??
    {
        let open = locked { state in
            guard state.disconnection == nil else { return false }
            state.delivery = (nil, pthread_self())
            return true
        }
        guard open else { return nil }
        defer { locked { $0.delivery = nil } }
        return .some(handler(call))
    }

    private func disconnect(_ reason: DBusDisconnection) {
        let first = locked { state in
            guard state.disconnection == nil else { return false }
            state.disconnection = reason
            return true
        }
        if first {
            transport.shutdown()
        }
    }

    // MARK: Sending

    func send(_ message: DBusMessage) throws(DBusCallError) -> UInt32 {
        try locked { state throws(DBusCallError) in try Self.queue(message, in: &state) }
    }

    private static func queue(_ message: DBusMessage, in state: inout State) throws(DBusCallError) -> UInt32 {
        if let disconnection = state.disconnection { throw .disconnected(disconnection) }
        do throws(DBusProtocolError) {
            return try state.core.send(message)
        } catch {
            throw .invalidMessage(error)
        }
    }

    func call(_ message: DBusMessage, timeout: Duration) throws(DBusCallError) -> DBusReceivedMessage {
        let deadline = Deadline(after: timeout)
        let serial = try locked { state throws(DBusCallError) in
            precondition(!state.isDeliveryThread, "A handler made a blocking call")
            let serial = try Self.queue(message, in: &state)
            state.replies[serial] = .waiting
            return serial
        }
        return try awaitReply(to: serial, until: deadline)
    }

    private func awaitReply(to serial: UInt32, until deadline: Deadline) throws(DBusCallError) -> DBusReceivedMessage {
        condition.lock()
        defer { condition.unlock() }
        var timedOut = false
        while true {
            if case .arrived(let reply)? = state.replies[serial] {
                state.replies[serial] = nil
                if let error = reply.remoteError { throw .remote(error) }
                return reply
            }
            if let disconnection = state.disconnection {
                state.replies[serial] = nil
                throw .disconnected(disconnection)
            }
            if timedOut {
                state.replies[serial] = nil
                state.core.abandonReply(to: serial)
                throw .timedOut
            }
            timedOut = !condition.wait(until: deadline)
        }
    }

    // MARK: Subscriptions

    func subscribe(
        _ rule: DBusMatchRule, handler: @escaping @Sendable (DBusReceivedMessage) -> Void
    ) throws(DBusCallError) -> DBusSubscription {
        let deadline = Deadline(after: DBusBusConnection.defaultTimeout)
        // Everything goes out in one hold, so the bus answers in this order:
        // the owner lookup lands before the rule's own AddMatch reply, and no
        // other caller's messages fall between.
        let (id, awaited) = try locked { state throws(DBusCallError) in
            precondition(!state.isDeliveryThread, "A handler made a blocking call")
            if let disconnection = state.disconnection { throw .disconnected(disconnection) }
            let id = state.nextSubscriptionID
            state.nextSubscriptionID += 1
            state.subscriptions[id] = Subscription(rule: rule, handler: handler)
            var awaited: [UInt32] = []
            do throws(DBusCallError) {
                if let sender = rule.sender, State.isTracked(sender) {
                    if state.owners[sender] == nil {
                        state.owners[sender] = (owner: nil, subscribers: 1)
                        awaited.append(
                            try Self.queue(Self.busCall("AddMatch", Self.ownerRule(sender).text), in: &state))
                        let lookup = try Self.queue(Self.busCall("GetNameOwner", sender), in: &state)
                        state.ownerLookups[lookup] = sender
                    } else {
                        state.owners[sender]?.subscribers += 1
                    }
                }
                awaited.append(try Self.queue(Self.busCall("AddMatch", rule.text), in: &state))
            } catch {
                Self.remove(id, from: &state)
                throw error
            }
            for serial in awaited {
                state.replies[serial] = .waiting
            }
            return (id, awaited)
        }
        do throws(DBusCallError) {
            for serial in awaited {
                _ = try awaitReply(to: serial, until: deadline)
            }
        } catch {
            unsubscribe(id)
            throw error
        }
        return DBusSubscription(engine: self, id: id)
    }

    func unsubscribe(_ id: UInt64) {
        locked { state in Self.remove(id, from: &state) }
    }

    private static func remove(_ id: UInt64, from state: inout State) {
        guard let subscription = state.subscriptions.removeValue(forKey: id) else { return }
        // Fire and forget: a disconnected bus holds no rules to remove.
        var removals = [subscription.rule]
        if let sender = subscription.rule.sender, State.isTracked(sender), var tracked = state.owners[sender] {
            tracked.subscribers -= 1
            state.owners[sender] = tracked.subscribers > 0 ? tracked : nil
            if tracked.subscribers == 0 {
                removals.append(ownerRule(sender))
            }
        }
        for rule in removals {
            var message = busCall("RemoveMatch", rule.text)
            message.header.flags.insert(.noReplyExpected)
            _ = try? queue(message, in: &state)
        }
    }

    private static func ownerRule(_ name: String) -> DBusMatchRule {
        DBusMatchRule(
            sender: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: "NameOwnerChanged",
            arg0: name)
    }

    private static func busCall(_ member: String, _ argument: String) -> DBusMessage {
        .methodCall(
            destination: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: member,
            body: [.string(argument)])
    }

    // MARK: The threads

    private func runWriter() {
        while true {
            condition.lock()
            while !state.core.hasOutbound, state.disconnection == nil {
                condition.wait()
            }
            let disconnected = state.disconnection != nil
            let bytes = disconnected ? [] : state.core.takeOutbound()
            condition.unlock()
            if disconnected { return }
            do throws(DBusTransportError) {
                try transport.write(bytes)
            } catch {
                disconnect(.transport(error))
                return
            }
        }
    }

    private func runReader() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65_536, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count: Int
            do throws(DBusTransportError) {
                count = try transport.read(into: buffer)
            } catch {
                disconnect(.transport(error))
                return
            }
            guard count > 0 else {
                disconnect(.endOfStream)
                return
            }
            let received = locked { state -> Result<[DBusConnection.Event], DBusConnectionError>? in
                guard state.disconnection == nil else { return nil }
                do throws(DBusConnectionError) {
                    return .success(try state.core.receive(UnsafeRawBufferPointer(rebasing: buffer[0..<count])))
                } catch {
                    return .failure(error)
                }
            }
            switch received {
            case nil:
                return
            case .failure(let error)?:
                disconnect(.connection(error))
                return
            case .success(let events)?:
                for event in events {
                    handle(event)
                }
            }
        }
    }

    private func handle(_ event: DBusConnection.Event) {
        switch event {
        case .ready(let uniqueName):
            locked { $0.uniqueName = uniqueName }
        case .reply(let serial, let reply):
            locked { state in
                if let name = state.ownerLookups.removeValue(forKey: serial) {
                    // NameHasNoOwner is the bus's answer for a name nobody holds.
                    let owner = try? reply.decodeBody(expecting: "s").first?.string()
                    state.owners[name]?.owner = reply.header.kind == .methodReturn ? owner : nil
                }
                if state.replies[serial] != nil {
                    state.replies[serial] = .arrived(reply)
                }
            }
        case .signal(let signal):
            let matching = locked { state in
                Self.followOwnerChange(signal, in: &state)
                return state.subscriptions
                    .filter { $0.value.rule.matches(signal, senderOwner: state.owner(of: $0.value.rule.sender)) }
                    .map(\.key).sorted()
            }
            // Each handler runs only while its subscription is still
            // registered, which `cancel()` and `close()` wait on.
            for id in matching {
                deliver(signal, to: id)
            }
        case .methodCall(let call):
            let reply: DBusMessage?
            if let onMethodCall {
                guard let answered = answer(call, with: onMethodCall) else { return }
                reply = answered
            } else {
                reply = .error(
                    replyingTo: call, name: "org.freedesktop.DBus.Error.UnknownMethod",
                    message: "No method \(call.header.member ?? "") at \(call.header.path?.rawValue ?? "")")
            }
            guard let reply, !call.header.flags.contains(.noReplyExpected) else { return }
            do throws(DBusCallError) {
                _ = try send(reply)
            } catch {
                // Disconnected, so there is no one to answer; or the handler
                // built an invalid reply, which is its bug.
                if case .invalidMessage = error {
                    assertionFailure("The method-call handler returned an invalid reply: \(error)")
                }
            }
        }
    }

    /// Applies a `NameOwnerChanged` to a tracked name: one the bus itself sent,
    /// as `ownerRule(_:)`, the rule registered for it, defines.
    private static func followOwnerChange(_ signal: DBusReceivedMessage, in state: inout State) {
        guard let arguments = try? signal.decodeBody(expecting: "sss"),
            case .string(let name) = arguments[0], case .string(let newOwner) = arguments[2],
            state.owners[name] != nil, ownerRule(name).matches(signal, senderOwner: DBusBus.name)
        else { return }
        state.owners[name]?.owner = newOwner.isEmpty ? nil : newOwner
    }
}

#endif
