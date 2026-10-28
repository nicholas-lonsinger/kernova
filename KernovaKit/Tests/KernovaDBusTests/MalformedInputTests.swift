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

    @Test("The corpus is every sample in both byte orders")
    func corpusIsComplete() {
        #expect(Self.corpus.count == sampleMessages.count * 2)
    }

    @Test("Every prefix of a message is refused as truncated", arguments: corpus)
    func truncations(bytes: [UInt8]) {
        for length in 0..<bytes.count {
            #expect(throws: DBusProtocolError.self) { try DBusReceivedMessage.decode(Array(bytes[0..<length])) }
        }
    }

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

    @Test("Seeded multi-byte corruption either throws or yields a decodable body", arguments: corpus.indices)
    func seededMutations(corpusIndex: Int) throws {
        let bytes = Self.corpus[corpusIndex]
        var state = UInt64(corpusIndex) &+ 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            // xorshift64*, seeded by the corpus index.
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
        for _ in 0..<2_000 {
            var mutated = bytes
            for _ in 0..<(1 + Int(next() % 4)) {
                mutated[Int(next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: next())
            }
            try Self.check(mutated)
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
