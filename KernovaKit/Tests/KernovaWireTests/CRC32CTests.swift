#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaPortableTestSupport
import KernovaWire
import Testing

@Suite("CRC32C")
struct CRC32CTests {
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

    @Test("RFC 3720 B.4 vectors", arguments: rfc3720)
    func rfc3720Vector(_ vector: Vector) {
        var crc = CRC32C()
        crc.update(vector.bytes)
        #expect(crc.value == vector.checksum)
    }

    /// CRC-32C one bit at a time, straight from the polynomial: a reference no
    /// part of `CRC32C` shares.
    private static func bitwise(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    @Test("The checksum matches the polynomial over seeded buffers of every alignment, split across updates")
    func matchesThePolynomial() {
        #expect(Self.bitwise(Array("123456789".utf8)) == 0xE306_9283)
        var generator = SplitMix64(seed: 0x82F6_3B78)
        let buffer = generator.bytes(20_000)
        buffer.withUnsafeBytes { all in
            for _ in 0..<300 {
                let start = Int.random(in: 0..<64, using: &generator)
                let count = Int.random(in: 0...(all.count - start), using: &generator)
                let split = Int.random(in: 0...count, using: &generator)
                var crc = CRC32C()
                crc.update(UnsafeRawBufferPointer(rebasing: all[start..<(start + split)]))
                crc.update(UnsafeRawBufferPointer(rebasing: all[(start + split)..<(start + count)]))
                #expect(crc.value == Self.bitwise(all[start..<(start + count)]))
            }
            for count in 0...64 {
                var crc = CRC32C()
                crc.update(UnsafeRawBufferPointer(rebasing: all[3..<(3 + count)]))
                #expect(crc.value == Self.bitwise(all[3..<(3 + count)]))
            }
        }
    }
}
