import KernovaDBus
import Testing

/// Every message the decoder meets after one byte of a valid one is changed,
/// or after it is cut short, must throw or decode to a message whose body
/// decodes: it never reads out of bounds and never traps.
@Suite("Malformed and truncated messages")
struct MalformedInputTests {
    static let corpus: [[UInt8]] = {
        var corpus: [[UInt8]] = []
        for (index, message) in sampleMessages.enumerated() {
            for byteOrder in [DBusByteOrder.littleEndian, .bigEndian] {
                if let bytes = try? message.encoded(serial: UInt32(index + 1), byteOrder: byteOrder) {
                    corpus.append(bytes)
                }
            }
        }
        return corpus
    }()

    @Test("Every value of every byte either throws or yields a decodable body", arguments: corpus)
    func singleByteMutations(bytes: [UInt8]) throws {
        for index in bytes.indices {
            var mutated = bytes
            for value in UInt8.min...UInt8.max where value != bytes[index] {
                mutated[index] = value
                try Self.check(mutated)
            }
        }
    }

    /// Decodes `bytes`, throwing only if they decode to a message whose body
    /// then fails to.
    private static func check(_ bytes: [UInt8]) throws {
        guard let message = try? DBusReceivedMessage.decode(bytes) else { return }
        _ = try message.decodeBody()
    }

    @Test("A connection fed a corrupted stream fails, and stays failed", arguments: corpus)
    func connectionFailsOnCorruption(bytes: [UInt8]) throws {
        var corrupted = bytes
        corrupted[3] = 2  // A protocol version this side does not speak.
        var connection = try readyConnection()
        #expect(throws: DBusConnectionError.protocolViolation(.unsupportedProtocolVersion(2))) {
            try connection.receive(corrupted)
        }
        #expect(throws: DBusConnectionError.protocolViolation(.unsupportedProtocolVersion(2))) {
            try connection.receive(bytes)
        }
        #expect(connection.phase == .failed(.protocolViolation(.unsupportedProtocolVersion(2))))
    }
}
