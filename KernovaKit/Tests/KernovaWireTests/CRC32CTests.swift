#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import Testing

@Suite("CRC32C")
struct CRC32CTests {
    @Test("The check value of ASCII 123456789 is 0xE3069283")
    func checkValue() {
        #expect(CRC32C.checksum(Data("123456789".utf8)) == 0xE306_9283)
        #expect(CRC32C.checksum(Data()) == 0)
    }

    struct Vector: Sendable, CustomTestStringConvertible {
        var name: String
        var bytes: [UInt8]
        var checksum: UInt32
        var testDescription: String { name }
    }

    /// RFC 3720 appendix B.4.
    static let rfc3720: [Vector] = [
        Vector(name: "32 bytes of zeros", bytes: [UInt8](repeating: 0, count: 32), checksum: 0x8A91_36AA),
        Vector(name: "32 bytes of ones", bytes: [UInt8](repeating: 0xFF, count: 32), checksum: 0x62A8_AB43),
        Vector(name: "32 incrementing bytes", bytes: (0..<32).map { UInt8($0) }, checksum: 0x46DD_794E),
        Vector(name: "32 decrementing bytes", bytes: (0..<32).reversed().map { UInt8($0) }, checksum: 0x113F_DB5C),
        Vector(
            name: "an iSCSI read command PDU",
            bytes: [
                0x01, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x18,
                0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ], checksum: 0xD996_3A56),
    ]

    @Test("RFC 3720 B.4 vectors, through both implementations", arguments: rfc3720)
    func rfc3720Vector(_ vector: Vector) {
        #expect(CRC32C.checksum(vector.bytes) == vector.checksum)
        let table = vector.bytes.withUnsafeBytes { CRC32C.tableAdvance(0xFFFF_FFFF, over: $0) } ^ 0xFFFF_FFFF
        #expect(table == vector.checksum)
    }

    @Test("Updating in pieces matches one pass, at every split of a short buffer")
    func incremental() {
        var generator = SeededGenerator(seed: 32)
        let bytes = generator.bytes(67)
        let whole = CRC32C.checksum(bytes)
        for offset in 0...bytes.count {
            var crc = CRC32C()
            for piece in bytes.split(at: [offset]) {
                crc.update(piece)
            }
            #expect(crc.value == whole, "split at \(offset)")
        }
    }

    #if arch(arm64) || arch(x86_64)
    @Test("The table and the CPU instructions agree over seeded buffers of every alignment")
    func tableMatchesHardware() {
        var generator = SeededGenerator(seed: 0x82F6_3B78)
        let buffer = generator.bytes(20_000)
        buffer.withUnsafeBytes { all in
            for _ in 0..<300 {
                let start = Int.random(in: 0..<64, using: &generator)
                let count = Int.random(in: 0...(all.count - start), using: &generator)
                let slice = UnsafeRawBufferPointer(rebasing: all[start..<(start + count)])
                let seed = UInt32.random(in: .min ... .max, using: &generator)
                #expect(CRC32C.tableAdvance(seed, over: slice) == CRC32C.hardwareAdvance(seed, over: slice))
            }
            for count in 0...64 {
                let slice = UnsafeRawBufferPointer(rebasing: all[3..<(3 + count)])
                #expect(
                    CRC32C.tableAdvance(0xFFFF_FFFF, over: slice) == CRC32C.hardwareAdvance(0xFFFF_FFFF, over: slice))
            }
        }
    }
    #endif
}
