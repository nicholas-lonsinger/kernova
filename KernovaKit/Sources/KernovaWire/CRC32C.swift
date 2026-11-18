#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CKernovaShims

/// CRC-32C (Castagnoli): reflected polynomial `0x82F63B78`, initial value and
/// final XOR `0xFFFFFFFF`. The checksum of ASCII `123456789` is `0xE3069283`.
///
/// It runs on the CPU's CRC32C instructions: the Armv8 CRC32 extension on
/// arm64, SSE4.2 on x86_64.
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

    #if arch(arm64) || arch(x86_64)
    /// Advances a raw register with the CPU's CRC32C instructions.
    private static func advance(_ register: UInt32, over buffer: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return register }
        return kernova_crc32c_hardware_update(register, base.assumingMemoryBound(to: UInt8.self), buffer.count)
    }
    #else
    #error("CRC32C runs on the CRC32C instructions of arm64 or x86_64")
    #endif
}
