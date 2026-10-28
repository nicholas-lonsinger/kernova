#if os(Linux)
import Foundation
import KernovaDBus
import KernovaPlatformLinux
import Testing

/// A bus the test plays: it accepts SASL EXTERNAL, answers Hello, AddMatch and
/// GetNameOwner, and puts every message the connection writes into `written`,
/// in order.
final class RecordingTransport: DBusTransport, @unchecked Sendable {
    let written = Inbox<DBusReceivedMessage>()

    private enum Phase {
        case authenticating, awaitingBegin, messages
    }

    private let condition = NSCondition()
    // Read and written only while `condition` is locked.
    private var toClient: [UInt8] = []
    private var fromClient: [UInt8] = []
    private var phase = Phase.authenticating
    private var serial: UInt32 = 1
    private var isShut = false

    func read(into buffer: UnsafeMutableRawBufferPointer) throws(DBusTransportError) -> Int {
        condition.lock()
        defer { condition.unlock() }
        while toClient.isEmpty, !isShut {
            condition.wait()
        }
        let count = min(buffer.count, toClient.count)
        buffer.copyBytes(from: toClient[0..<count])
        toClient.removeFirst(count)
        return count
    }

    func write(_ bytes: [UInt8]) throws(DBusTransportError) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        fromClient += bytes
        while consumeOne() {}
    }

    func shutdown() {
        condition.lock()
        isShut = true
        condition.broadcast()
        condition.unlock()
    }

    /// Consumes one line or message the client wrote, if it has all arrived.
    private func consumeOne() -> Bool {
        switch phase {
        case .authenticating, .awaitingBegin:
            guard let end = fromClient.indices.dropLast().first(where: { fromClient[$0...].starts(with: [13, 10]) })
            else { return false }
            fromClient.removeFirst(end + 2)
            if phase == .authenticating {
                toClient += Array("OK 0123456789abcdef0123456789abcdef\r\n".utf8)
                phase = .awaitingBegin
            } else {
                phase = .messages
            }
            return true
        case .messages:
            guard fromClient.count >= 16 else { return false }
            func uint32(at offset: Int) -> Int {
                (0..<4).reduce(0) { $0 | Int(fromClient[offset + $1]) << (8 * $1) }
            }
            let length = ((16 + uint32(at: 12) + 7) & ~7) + uint32(at: 4)
            guard fromClient.count >= length else { return false }
            let bytes = Array(fromClient[0..<length])
            fromClient.removeFirst(length)
            guard let message = try? DBusReceivedMessage.decode(bytes) else { return true }
            written.put(message)
            answer(message)
            return true
        }
    }

    private func answer(_ call: DBusReceivedMessage) {
        guard call.header.kind == .methodCall, !call.header.flags.contains(.noReplyExpected) else { return }
        let body: [DBusValue]
        switch call.header.member {
        case "Hello": body = [.string(":1.1")]
        case "GetNameOwner": body = [.string(":1.9")]
        default: body = []
        }
        var reply = DBusMessage.methodReturn(replyingTo: call, body: body)
        reply.header.sender = DBusBus.name
        serial += 1
        if let bytes = try? reply.encoded(serial: serial) {
            toClient += bytes
        }
    }
}

@Suite("Subscriptions register and remove their rules with the bus")
struct SubscriptionRuleTests {
    /// The next message written, as its member and its first string argument.
    static func next(_ transport: RecordingTransport) throws -> String {
        let message = try transport.written.next()
        let argument = (try? message.decodeBody().first?.string()) ?? ""
        let reply = message.header.flags.contains(.noReplyExpected) ? " (no reply)" : ""
        return "\(message.header.member ?? "") \(argument)\(reply)"
    }

    @Test("cancel() writes RemoveMatch for its rule, and for the owner rule once its name's last subscriber is gone")
    func removeMatch() throws {
        let transport = RecordingTransport()
        let connection = try DBusBusConnection(transport: transport, uid: 0)
        #expect(try Self.next(transport) == "Hello ")
        let rule = BusConnectionTests.tickRule
        let ownerRule = DBusMatchRule(
            sender: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: "NameOwnerChanged",
            arg0: BusConnectionTests.serviceName)

        let first = try connection.subscribe(rule) { _ in }
        #expect(try Self.next(transport) == "AddMatch \(ownerRule.text)")
        #expect(try Self.next(transport) == "GetNameOwner \(BusConnectionTests.serviceName)")
        #expect(try Self.next(transport) == "AddMatch \(rule.text)")
        let second = try connection.subscribe(rule) { _ in }
        #expect(try Self.next(transport) == "AddMatch \(rule.text)")

        first.cancel()
        #expect(try Self.next(transport) == "RemoveMatch \(rule.text) (no reply)")
        first.cancel()
        second.cancel()
        #expect(try Self.next(transport) == "RemoveMatch \(rule.text) (no reply)")
        #expect(try Self.next(transport) == "RemoveMatch \(ownerRule.text) (no reply)")
        connection.close()
        #expect(transport.written.isEmpty)
    }
}
#endif
