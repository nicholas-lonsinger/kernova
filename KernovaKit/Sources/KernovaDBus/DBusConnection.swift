/// A client connection to a message bus, with no I/O: it is fed the bytes the
/// transport reads and hands back the bytes to write and what happened.
///
/// It authenticates with SASL EXTERNAL, then sends `Hello` as the first
/// message; messages sent before the bus accepted the authentication wait and
/// follow `Hello`. It numbers each message it sends and matches replies to the
/// calls still awaiting one; a reply to anything else is dropped.
///
/// The first malformed byte from the server fails the connection: every later
/// `receive(_:)` throws the same error, and nothing more is written.
public struct DBusConnection: Sendable {
    /// What a call to `receive(_:)` found.
    public enum Event: Sendable, Hashable {
        /// The bus answered `Hello`: messages flow, and `uniqueName` is this
        /// connection's name on the bus.
        case ready(uniqueName: String)
        /// The METHOD_RETURN or ERROR answering the call sent with `serial`.
        case reply(serial: UInt32, DBusReceivedMessage)
        /// A SIGNAL.
        case signal(DBusReceivedMessage)
        /// A METHOD_CALL to this connection.
        case methodCall(DBusReceivedMessage)
    }

    /// Where the connection is.
    public enum Phase: Sendable, Hashable {
        /// Waiting for the server to accept the authentication.
        case authenticating
        /// Authenticated, and waiting for the reply to `Hello`.
        case awaitingHello
        /// Messages flow; this connection's name on the bus is `uniqueName`.
        case ready(uniqueName: String)
        /// Failed for good.
        case failed(DBusConnectionError)
    }

    /// Where the connection is.
    public private(set) var phase: Phase = .authenticating

    private let byteOrder: DBusByteOrder
    private var authenticator = DBusAuthenticator()
    private var outbound: [UInt8]
    /// Messages sent before authentication finished, `Hello` first.
    private var held: [UInt8]
    private var helloSerial: UInt32 = 0
    private var serials = DBusSerialCounter()
    private var awaitingReply: Set<UInt32> = []
    private var inbound: [UInt8] = []
    private var inboundStart = 0

    /// A connection authenticating as `uid`, writing messages in `byteOrder`.
    public init(uid: UInt32, byteOrder: DBusByteOrder = .littleEndian) {
        self.byteOrder = byteOrder
        outbound = DBusAuthenticator.opening(uid: uid)
        held = []
        let hello = DBusMessage.methodCall(
            destination: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: "Hello")
        do {
            helloSerial = try send(hello)
        } catch {
            preconditionFailure("Hello, a constant message, did not encode: \(error)")
        }
    }

    /// Whether bytes are waiting to be written.
    public var hasOutbound: Bool { !outbound.isEmpty }

    /// The bytes to write next, in order; each is returned once.
    public mutating func takeOutbound() -> [UInt8] {
        defer { outbound = [] }
        return outbound
    }

    /// Queues `message` and returns the serial it was given. A METHOD_CALL
    /// without NO_REPLY_EXPECTED then awaits its reply, which a later
    /// `receive(_:)` returns as `Event.reply`.
    ///
    /// An invalid message throws and changes nothing. Once the connection has
    /// failed, the message is numbered but never written.
    @discardableResult
    public mutating func send(_ message: DBusMessage) throws(DBusProtocolError) -> UInt32 {
        let serial = serials.candidate(skipping: awaitingReply)
        let bytes = try message.encoded(serial: serial, byteOrder: byteOrder)
        serials.consume(serial)
        if message.header.kind == .methodCall, !message.header.flags.contains(.noReplyExpected) {
            awaitingReply.insert(serial)
        }
        switch phase {
        case .authenticating: held += bytes
        case .awaitingHello, .ready: outbound += bytes
        case .failed: break
        }
        return serial
    }

    /// Stops awaiting the reply to the call sent with `serial`, as when its
    /// caller gave up; the reply, if it comes, is dropped.
    public mutating func abandonReply(to serial: UInt32) {
        awaitingReply.remove(serial)
    }

    /// Feeds bytes the transport read, and returns what they completed.
    public mutating func receive(_ bytes: some Collection<UInt8>) throws(DBusConnectionError) -> [Event] {
        if case .failed(let error) = phase { throw error }
        do throws(DBusConnectionError) {
            return try process(Array(bytes))
        } catch {
            phase = .failed(error)
            outbound = []
            held = []
            throw error
        }
    }

    private mutating func process(_ bytes: [UInt8]) throws(DBusConnectionError) -> [Event] {
        var messageBytes = bytes[...]
        if case .authenticating = phase {
            let step: DBusAuthenticator.Step
            do throws(DBusAuthenticationError) {
                step = try authenticator.receive(messageBytes)
            } catch {
                throw .authentication(error)
            }
            outbound += authenticator.takeOutbound()
            guard case .authenticated(_, let remainder) = step else { return [] }
            outbound += Array("BEGIN\r\n".utf8) + held
            held = []
            phase = .awaitingHello
            messageBytes = remainder[...]
        }
        inbound += messageBytes
        var events: [Event] = []
        framing: while inbound.count - inboundStart >= 16 {
            let message: DBusReceivedMessage?
            do throws(DBusProtocolError) {
                let length = try DBusReceivedMessage.length(
                    fixedHeader: inbound[inboundStart..<(inboundStart + 16)])
                guard inbound.count - inboundStart >= length else { break framing }
                message = try DBusReceivedMessage.decode(Array(inbound[inboundStart..<(inboundStart + length)]))
                inboundStart += length
            } catch {
                throw .protocolViolation(error)
            }
            if let message, let event = try route(message) {
                events.append(event)
            }
        }
        if inboundStart > 0, inboundStart * 2 >= inbound.count {
            inbound.removeFirst(inboundStart)
            inboundStart = 0
        }
        return events
    }

    private mutating func route(_ message: DBusReceivedMessage) throws(DBusConnectionError) -> Event? {
        switch message.header.kind {
        case .methodCall:
            return .methodCall(message)
        case .signal:
            return .signal(message)
        case .methodReturn, .error:
            guard let serial = message.header.replySerial, awaitingReply.remove(serial) != nil else { return nil }
            guard serial == helloSerial else { return .reply(serial: serial, message) }
            if let error = message.remoteError { throw .helloRefused(error) }
            let uniqueName: String
            do throws(DBusProtocolError) {
                let body = try message.decodeBody(expecting: "s")
                guard case .string(let name) = body[0], DBusNameKind.bus.isValid(name) else {
                    throw .invalidName(.bus, "\(body[0])")
                }
                uniqueName = name
            } catch {
                throw .protocolViolation(error)
            }
            phase = .ready(uniqueName: uniqueName)
            return .ready(uniqueName: uniqueName)
        }
    }
}

/// Why a `DBusConnection` failed.
public enum DBusConnectionError: Error, Hashable, Sendable {
    /// The server did not authenticate this side.
    case authentication(DBusAuthenticationError)
    /// The server sent bytes that are not a valid message stream.
    case protocolViolation(DBusProtocolError)
    /// The bus answered `Hello` with an error.
    case helloRefused(DBusRemoteError)
}

/// The message bus's own name, object and interface.
public enum DBusBus {
    /// `org.freedesktop.DBus`.
    public static let name = "org.freedesktop.DBus"
    /// `/org/freedesktop/DBus`.
    public static let path: DBusObjectPath = "/org/freedesktop/DBus"
    /// `org.freedesktop.DBus`.
    public static let interface = "org.freedesktop.DBus"
}

/// Numbers a connection's messages: 1 upward, wrapping past 0.
struct DBusSerialCounter: Sendable {
    /// The serial tried first for the next message.
    private(set) var next: UInt32

    init(next: UInt32 = 1) {
        self.next = next
    }

    /// The serial the next message takes: `next`, stepped past any serial
    /// whose call still awaits its reply, so a reply never matches two calls.
    func candidate(skipping awaiting: Set<UInt32>) -> UInt32 {
        var serial = next
        while awaiting.contains(serial) {
            serial = Self.successor(of: serial)
        }
        return serial
    }

    /// Records that a message took `serial`.
    mutating func consume(_ serial: UInt32) {
        next = Self.successor(of: serial)
    }

    private static func successor(of serial: UInt32) -> UInt32 {
        serial == .max ? 1 : serial + 1
    }
}
