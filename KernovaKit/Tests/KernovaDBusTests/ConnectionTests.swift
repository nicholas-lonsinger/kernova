@testable import KernovaDBus
import Testing

let serverGUID = "0123456789abcdef0123456789ABCDEF"

func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

/// A message from the bus to this side, as the bus would number and send it.
func fromBus(_ message: DBusMessage, serial: UInt32, sender: String = "org.freedesktop.DBus") throws -> [UInt8] {
    var message = message
    message.header.sender = sender
    return try message.encoded(serial: serial)
}

/// The bus's answer to `Hello`, sent as serial 1.
func helloReply(uniqueName: String = ":1.7") throws -> [UInt8] {
    var reply = DBusMessage(header: DBusMessageHeader(kind: .methodReturn), body: [.string(uniqueName)])
    reply.header.replySerial = 1
    reply.header.destination = uniqueName
    return try fromBus(reply, serial: 1)
}

/// A connection the bus has authenticated and greeted, its output drained.
func readyConnection() throws -> DBusConnection {
    var connection = DBusConnection(uid: 1000)
    _ = try connection.receive(ascii("OK \(serverGUID)\r\n"))
    _ = try connection.receive(try helloReply())
    _ = connection.takeOutbound()
    return connection
}

/// The messages in `bytes`, which must be whole messages back to back.
func messages(in bytes: [UInt8]) throws -> [DBusReceivedMessage] {
    var result: [DBusReceivedMessage] = []
    var rest = bytes[...]
    while !rest.isEmpty {
        let length = 16 + (Int(rest[rest.startIndex + 12]) | Int(rest[rest.startIndex + 13]) << 8)
        let bodyLength = Int(rest[rest.startIndex + 4]) | Int(rest[rest.startIndex + 5]) << 8
        let total = ((length + 7) & ~7) + bodyLength
        result.append(try #require(try DBusReceivedMessage.decode(Array(rest.prefix(total)))))
        rest = rest.dropFirst(total)
    }
    return result
}

@Suite("DBusConnection: SASL EXTERNAL, Hello, serials and reply matching")
struct ConnectionTests {
    @Test("The transcript: NUL and AUTH EXTERNAL, then BEGIN and Hello after OK")
    func transcript() throws {
        var connection = DBusConnection(uid: 1000)
        #expect(connection.phase == .authenticating)
        #expect(connection.takeOutbound() == [0] + ascii("AUTH EXTERNAL 31303030\r\n"))
        #expect(!connection.hasOutbound)

        // A call made before the bus accepts waits behind Hello.
        let early = try connection.send(
            .methodCall(destination: "org.example.Peer", path: "/", interface: nil, member: "Early"))
        #expect(early == 2)
        #expect(!connection.hasOutbound)

        #expect(try connection.receive(ascii("OK \(serverGUID)\r\n")).isEmpty)
        #expect(connection.phase == .awaitingHello)
        let afterOK = connection.takeOutbound()
        let begin = ascii("BEGIN\r\n")
        #expect(Array(afterOK.prefix(begin.count)) == begin)
        let sent = try messages(in: Array(afterOK.dropFirst(begin.count)))
        #expect(sent.map(\.header.member) == ["Hello", "Early"])
        #expect(sent.map(\.serial) == [1, 2])
        #expect(sent[0].header.destination == "org.freedesktop.DBus")
        #expect(sent[0].header.path == "/org/freedesktop/DBus")
        #expect(sent[0].header.interface == "org.freedesktop.DBus")

        #expect(try connection.receive(try helloReply()) == [.ready(uniqueName: ":1.7")])
        #expect(connection.phase == .ready(uniqueName: ":1.7"))
    }

    @Test("Root's uid is the single digit 0, hex-encoded")
    func rootUID() {
        var connection = DBusConnection(uid: 0)
        #expect(connection.takeOutbound() == [0] + ascii("AUTH EXTERNAL 30\r\n"))
    }

    @Test("Lines may arrive a byte at a time, and messages may follow OK in the same read")
    func splitLines() throws {
        var connection = DBusConnection(uid: 1000)
        let stream = ascii("OK \(serverGUID)\r\n") + (try helloReply())
        var events: [DBusConnection.Event] = []
        for byte in stream {
            events += try connection.receive([byte])
        }
        #expect(events == [.ready(uniqueName: ":1.7")])

        var together = DBusConnection(uid: 1000)
        #expect(try together.receive(stream) == [.ready(uniqueName: ":1.7")])
    }

    @Test("A command it does not know is answered with ERROR, and the wait for OK goes on")
    func unknownCommand() throws {
        var connection = DBusConnection(uid: 1000)
        _ = connection.takeOutbound()
        #expect(try connection.receive(ascii("AGREE_UNIX_FD\r\n")).isEmpty)
        #expect(connection.takeOutbound() == ascii("ERROR\r\n"))
        #expect(connection.phase == .authenticating)
        _ = try connection.receive(ascii("OK \(serverGUID)\r\n"))
        #expect(connection.phase == .awaitingHello)
    }

    static let refusals: [(String, DBusAuthenticationError)] = [
        ("REJECTED DBUS_COOKIE_SHA1 ANONYMOUS\r\n", .rejected(mechanisms: ["DBUS_COOKIE_SHA1", "ANONYMOUS"])),
        ("REJECTED\r\n", .rejected(mechanisms: [])),
        ("ERROR not today\r\n", .serverError("not today")),
        ("DATA 00\r\n", .unexpectedCommand("DATA")),
        ("OK abc\r\n", .invalidLine),
        ("OK \(serverGUID)z\r\n", .invalidLine),
        ("OK\u{0}\r\n", .invalidLine),
        ("OK é\r\n", .invalidLine),
        (String(repeating: "X", count: 5000), .invalidLine),
    ]

    @Test("A refusal or malformed line fails the connection for good", arguments: refusals)
    func refusal(line: String, error: DBusAuthenticationError) throws {
        var connection = DBusConnection(uid: 1000)
        _ = connection.takeOutbound()
        #expect(throws: DBusConnectionError.authentication(error)) { try connection.receive(ascii(line)) }
        #expect(connection.phase == .failed(.authentication(error)))
        #expect(!connection.hasOutbound)
        #expect(throws: DBusConnectionError.authentication(error)) {
            try connection.receive(ascii("OK \(serverGUID)\r\n"))
        }
        _ = try connection.send(.methodCall(destination: nil, path: "/", interface: nil, member: "Late"))
        #expect(!connection.hasOutbound)
    }

    @Test("A Hello the bus refuses fails the connection")
    func helloRefused() throws {
        var connection = DBusConnection(uid: 1000)
        _ = try connection.receive(ascii("OK \(serverGUID)\r\n"))
        var refusal = DBusMessage(header: DBusMessageHeader(kind: .error), body: [.string("Full")])
        refusal.header.replySerial = 1
        refusal.header.errorName = "org.freedesktop.DBus.Error.LimitsExceeded"
        let error = DBusRemoteError(name: "org.freedesktop.DBus.Error.LimitsExceeded", message: "Full")
        #expect(throws: DBusConnectionError.helloRefused(error)) {
            try connection.receive(try fromBus(refusal, serial: 1))
        }
    }

    @Test("Replies reach the call awaiting them; one to nothing awaited is dropped")
    func replyMatching() throws {
        var connection = try readyConnection()
        let call = DBusMessage.methodCall(destination: "org.example.Peer", path: "/", interface: nil, member: "Get")
        let first = try connection.send(call)
        let second = try connection.send(call)
        var noReply = call
        noReply.header.flags = .noReplyExpected
        let third = try connection.send(noReply)
        #expect([first, second, third] == [2, 3, 4])

        func reply(to serial: UInt32, value: UInt32) throws -> [UInt8] {
            var message = DBusMessage(header: DBusMessageHeader(kind: .methodReturn), body: [.uint32(value)])
            message.header.replySerial = serial
            return try fromBus(message, serial: 100 + serial, sender: ":1.9")
        }
        let events = try connection.receive(
            try reply(to: second, value: 2) + reply(to: first, value: 1) + reply(to: first, value: 9)
                + reply(to: third, value: 3) + reply(to: 999, value: 0))
        let replies = events.map { event -> (UInt32, [DBusValue])? in
            guard case .reply(let serial, let message) = event else { return nil }
            return (serial, (try? message.decodeBody()) ?? [])
        }
        #expect(replies.count == 2)
        #expect(replies[0]?.0 == second && replies[0]?.1 == [.uint32(2)])
        #expect(replies[1]?.0 == first && replies[1]?.1 == [.uint32(1)])
    }

    @Test("An abandoned call's late reply is dropped")
    func abandonedReply() throws {
        var connection = try readyConnection()
        let serial = try connection.send(
            .methodCall(destination: "org.example.Peer", path: "/", interface: nil, member: "Slow"))
        connection.abandonReply(to: serial)
        var reply = DBusMessage(header: DBusMessageHeader(kind: .methodReturn))
        reply.header.replySerial = serial
        #expect(try connection.receive(try fromBus(reply, serial: 50)).isEmpty)
    }

    @Test("Signals and method calls to this side come out as events")
    func incoming() throws {
        var connection = try readyConnection()
        let signal = try fromBus(sampleMessages[3], serial: 10, sender: ":1.3")
        var call = DBusMessage.methodCall(destination: ":1.7", path: "/", interface: nil, member: "Ping")
        call.header.sender = ":1.3"
        let events = try connection.receive(signal + (try call.encoded(serial: 11)))
        #expect(events.count == 2)
        guard case .signal(let received) = events[0], case .methodCall(let incoming) = events[1] else {
            Issue.record("Events: \(events)")
            return
        }
        #expect(received.header.member == "PropertiesChanged")
        #expect(incoming.serial == 11)

        let answer = try DBusMessage.methodReturn(replyingTo: incoming).encoded(serial: 5)
        let decoded = try #require(try DBusReceivedMessage.decode(answer))
        #expect(decoded.header.replySerial == 11)
        #expect(decoded.header.destination == ":1.3")
    }

    @Test("A message split anywhere arrives whole once its last byte does")
    func splitMessages() throws {
        let stream = try fromBus(sampleMessages[3], serial: 10) + (try fromBus(sampleMessages[3], serial: 11))
        for split in 1..<stream.count {
            var connection = try readyConnection()
            let events = try connection.receive(stream[0..<split]) + (try connection.receive(stream[split...]))
            #expect(events.count == 2)
        }
    }

    @Test("Serials skip 0 when they wrap, and any still awaiting a reply")
    func serialWrap() {
        var counter = DBusSerialCounter(next: .max)
        #expect(counter.candidate(skipping: []) == .max)
        counter.consume(.max)
        #expect(counter.next == 1)
        #expect(counter.candidate(skipping: [1, 2, 4]) == 3)
        #expect(DBusSerialCounter(next: .max).candidate(skipping: [.max, 1]) == 2)
    }

    @Test("Each message a connection sends takes the next serial after Hello's")
    func serialsAvoidAwaited() throws {
        var connection = try readyConnection()
        let call = DBusMessage.methodCall(destination: "org.example.Peer", path: "/", interface: nil, member: "M")
        #expect(try connection.send(call) == 2)
        #expect(try connection.send(call) == 3)
    }

    @Test("An invalid message throws and leaves the connection as it was")
    func invalidSend() throws {
        var connection = try readyConnection()
        let invalid = DBusMessage.methodCall(destination: "not a name", path: "/", interface: nil, member: "M")
        #expect(throws: DBusProtocolError.invalidName(.bus, "not a name")) { try connection.send(invalid) }
        #expect(!connection.hasOutbound)
        let valid = try connection.send(.methodCall(destination: nil, path: "/", interface: nil, member: "M"))
        #expect(valid == 2)
    }
}
