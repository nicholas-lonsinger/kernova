#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// SplitMix64: the same sequence for the same seed on every platform.
package struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    package init(seed: UInt64) {
        state = seed
    }

    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    package mutating func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        // Little-endian words: byte i is bits 8·(i mod 8) of word i/8. Frozen
        // transcripts name payloads by this generator, so the layout never changes.
        data.withUnsafeMutableBytes { buffer in
            var index = 0
            while index + 8 <= count {
                buffer.storeBytes(of: next().littleEndian, toByteOffset: index, as: UInt64.self)
                index += 8
            }
            if index < count {
                var word = next()
                while index < count {
                    buffer[index] = UInt8(truncatingIfNeeded: word)
                    word >>= 8
                    index += 1
                }
            }
        }
        return data
    }
}
