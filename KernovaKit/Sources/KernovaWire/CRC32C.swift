#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CKernovaShims

/// CRC-32C (Castagnoli): reflected polynomial `0x82F63B78`, initial value and
/// final XOR `0xFFFFFFFF`. The checksum of ASCII `123456789` is `0xE3069283`.
///
/// On arm64 and x86_64 it runs on the CPU's CRC32C instructions, which need the
/// Armv8 CRC32 extension or SSE4.2; elsewhere on a slicing-by-8 table.
public struct CRC32C: Sendable {
    private var register: UInt32 = 0xFFFF_FFFF

    /// A checksum of no bytes yet.
    public init() {}

    /// The checksum of every byte passed to `update(_:)` so far.
    public var value: UInt32 { register ^ 0xFFFF_FFFF }

    /// Extends the checksum over `bytes`.
    public mutating func update(_ bytes: some ContiguousBytes) {
        bytes.withUnsafeBytes { buffer in
            register = Self.advance(register, over: buffer)
        }
    }

    /// The checksum of `bytes`.
    public static func checksum(_ bytes: some ContiguousBytes) -> UInt32 {
        var crc = CRC32C()
        crc.update(bytes)
        return crc.value
    }

    private static func advance(_ register: UInt32, over buffer: UnsafeRawBufferPointer) -> UInt32 {
        #if arch(arm64) || arch(x86_64)
        hardwareAdvance(register, over: buffer)
        #else
        tableAdvance(register, over: buffer)
        #endif
    }

    #if arch(arm64) || arch(x86_64)
    /// Advances a raw register with the CPU's CRC32C instructions.
    package static func hardwareAdvance(_ register: UInt32, over buffer: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return register }
        return kernova_crc32c_hardware_update(register, base.assumingMemoryBound(to: UInt8.self), buffer.count)
    }
    #endif

    /// Advances a raw register with the slicing-by-8 table.
    package static func tableAdvance(_ register: UInt32, over buffer: UnsafeRawBufferPointer) -> UInt32 {
        var crc = register
        Self.table.withUnsafeBufferPointer { table in
            var index = 0
            let count = buffer.count
            while count - index >= 8 {
                let low =
                    crc
                    ^ (UInt32(buffer[index]) | UInt32(buffer[index + 1]) << 8 | UInt32(buffer[index + 2]) << 16
                        | UInt32(buffer[index + 3]) << 24)
                let high =
                    UInt32(buffer[index + 4]) | UInt32(buffer[index + 5]) << 8 | UInt32(buffer[index + 6]) << 16
                    | UInt32(buffer[index + 7]) << 24
                crc =
                    table[7 &* 256 &+ Int(low & 0xFF)] ^ table[6 &* 256 &+ Int((low >> 8) & 0xFF)]
                    ^ table[5 &* 256 &+ Int((low >> 16) & 0xFF)] ^ table[4 &* 256 &+ Int(low >> 24)]
                    ^ table[3 &* 256 &+ Int(high & 0xFF)] ^ table[2 &* 256 &+ Int((high >> 8) & 0xFF)]
                    ^ table[1 &* 256 &+ Int((high >> 16) & 0xFF)] ^ table[Int(high >> 24)]
                index += 8
            }
            while index < count {
                crc = table[Int((crc ^ UInt32(buffer[index])) & 0xFF)] ^ (crc >> 8)
                index += 1
            }
        }
        return crc
    }

    /// Eight 256-entry tables, flattened: entry `k * 256 + b` is byte `b`'s
    /// remainder carried through `k` further zero bytes.
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 8 * 256)
        for byte in 0..<256 {
            var crc = UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
            }
            table[byte] = crc
        }
        for slice in 1..<8 {
            for byte in 0..<256 {
                let previous = table[(slice - 1) * 256 + byte]
                table[slice * 256 + byte] = (previous >> 8) ^ table[Int(previous & 0xFF)]
            }
        }
        return table
    }()
}
