#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaWire
import Testing

/// Each record kind's exact bytes: `[kind][u32 length][u32 CRC32C over kind, length and payload][payload]`,
/// little-endian. The checksums were computed outside the codec, by a bitwise CRC-32C.
@Suite("Container golden vectors")
struct GoldenVectorTests {
    /// An unnamed FILE, depth 0, mode 0644, plain storage of 3 bytes.
    static let header = Data([
        0x01, 0x09, 0x00, 0x00, 0x00, 0x72, 0x7E, 0x2C, 0xAC,
        0x18, 0x02, 0x20, 0xA4, 0x03, 0x52, 0x02, 0x08, 0x03,
    ])
    /// The bytes `abc`.
    static let chunk = Data([0x02, 0x03, 0x00, 0x00, 0x00, 0x51, 0xA1, 0x7A, 0xF0, 0x61, 0x62, 0x63])
    /// 32 bytes of `a`: decompressed size 32, then one literal, a match at offset 1 of 26, and 5 literals.
    static let lz4Chunk = Data([
        0x03, 0x0F, 0x00, 0x00, 0x00, 0x07, 0xBD, 0x00, 0x34,
        0x20, 0x00, 0x00, 0x00, 0x1F, 0x61, 0x01, 0x00, 0x07, 0x50, 0x61, 0x61, 0x61, 0x61, 0x61,
    ])
    /// 4,096 zero bytes.
    static let zeroRun = Data([
        0x04, 0x08, 0x00, 0x00, 0x00, 0xA7, 0x69, 0x2A, 0x6D, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])
    /// One entry, 3 bytes.
    static let end = Data([0x05, 0x04, 0x00, 0x00, 0x00, 0x58, 0x0D, 0x99, 0xCF, 0x08, 0x01, 0x10, 0x03])

    @Test("The encoder writes a header, a chunk and an end record byte for byte")
    func encoderMatchesGoldenBytes() throws {
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        var header = EntryHeader()
        header.type = .file
        header.mode = 0o644
        header.plain.size = 3
        #expect(try encoder.entry(header) == Self.header)
        #expect(try encoder.bytes(Data("abc".utf8)) == Self.chunk)
        #expect(try encoder.end() == Self.end)
    }

    @Test("The encoder writes a zero run byte for byte")
    func encoderZeroRun() throws {
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try encoder.entry(plainFile(depth: 0, size: 4_096))
        #expect(try encoder.bytes(Data(count: 4_096)) == Self.zeroRun)
    }

    @Test("The decoder reads the golden LZ4 chunk and zero run")
    func decodesLZ4AndZeroRun() {
        let lz4 = decode(
            headerRecord(lz4File(depth: 0, size: 32)) + Self.lz4Chunk + endRecord(entries: 1, bytes: 32))
        #expect(lz4.error == nil)
        #expect(content(of: lz4.events) == Data(repeating: 0x61, count: 32))

        let zeros = decode(
            headerRecord(plainFile(depth: 0, size: 4_096)) + Self.zeroRun + endRecord(entries: 1, bytes: 4_096))
        #expect(zeros.error == nil)
        #expect(zeros.events.contains(.zeros(4_096)))
    }
}
