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
    @Test("A message split anywhere arrives whole once its last byte does")
    func splitMessages() throws {
        let stream = try fromBus(sampleMessages[3], serial: 10) + (try fromBus(sampleMessages[3], serial: 11))
        for split in 1..<stream.count {
            var connection = try readyConnection()
            let events = try connection.receive(stream[0..<split]) + (try connection.receive(stream[split...]))
            #expect(events.count == 2)
        }
    }
}
