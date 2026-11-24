#if os(Linux)
import Foundation
import KernovaDBus
import KernovaPlatformLinux
import KernovaPortableTestSupport

/// A bus the test plays: it accepts SASL EXTERNAL, answers Hello, AddMatch and
/// GetNameOwner, puts every message the connection writes into `written`, in
/// order, and sends the connection whatever `send(_:)` is given.
final class RecordingTransport: DBusTransport, @unchecked Sendable {
    let written = BlockingInbox<DBusReceivedMessage>()

    private enum Phase {
        case authenticating, awaitingBegin, messages
    }

    private let lock = NSLock()
    /// Signalled whenever a write or a shutdown may have left something for `read` to return.
    private let readable = DispatchSemaphore(value: 0)
    // Read and written only while `lock` is held.
    private var toClient: [UInt8] = []
    private var fromClient: [UInt8] = []
    private var phase = Phase.authenticating
    private var serial: UInt32 = 1
    private var isShut = false
    /// Where a read the test leaves waiting fails the test.
    private let waits = OffTaskWaits()

    /// Blocks, as a socket's read does, until the bus has bytes for the client or shuts — failing with `ETIMEDOUT`
    /// once the hold reaches its backstop, so a connection a test leaves open does not hold its reader thread
    /// for good.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws(DBusTransportError) -> Int {
        let backstop = Backstop("RecordingTransport.read(into:)")
        while true {
            lock.lock()
            if !toClient.isEmpty || isShut {
                let count = min(buffer.count, toClient.count)
                buffer.copyBytes(from: toClient[0..<count])
                toClient.removeFirst(count)
                lock.unlock()
                return count
            }
            lock.unlock()
            guard waits.run({ try backstop.wait(for: readable) }) else { throw .readFailed(errno: ETIMEDOUT) }
        }
    }

    func write(_ bytes: [UInt8]) throws(DBusTransportError) {
        lock.lock()
        fromClient += bytes
        while consumeOne() {}
        lock.unlock()
        readable.signal()
    }

    func shutdown() {
        lock.lock()
        isShut = true
        lock.unlock()
        readable.signal()
    }

    /// Sends `bytes` to the connection, as the bus would.
    func send(_ bytes: [UInt8]) {
        lock.lock()
        toClient += bytes
        lock.unlock()
        readable.signal()
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
#endif
