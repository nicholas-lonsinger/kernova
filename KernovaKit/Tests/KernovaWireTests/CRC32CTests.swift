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
