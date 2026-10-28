#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore

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

    /// A value in `range`, uniformly enough for scheduling.
    package mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
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

/// FNV-1a, 64-bit: the running hash of a transcript.
package struct FNV64: Sendable, Equatable {
    package private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    package init() {}

    /// Mixes `bytes` in eight at a time (a word-wise FNV variant, fast in debug builds).
    package mutating func add(_ bytes: Data) {
        var value = self.value
        bytes.withUnsafeBytes { buffer in
            let count = buffer.count
            var index = 0
            while index + 8 <= count {
                value = (value ^ buffer.loadUnaligned(fromByteOffset: index, as: UInt64.self)) &* 0x0000_0100_0000_01B3
                index += 8
            }
            while index < count {
                value = (value ^ UInt64(buffer[index])) &* 0x0000_0100_0000_01B3
                index += 1
            }
        }
        value = (value ^ UInt64(bytes.count)) &* 0x0000_0100_0000_01B3
        self.value = value
    }

    package mutating func add(_ number: UInt64) {
        var number = number
        for _ in 0..<8 {
            value = (value ^ (number & 0xFF)) &* 0x0000_0100_0000_01B3
            number >>= 8
        }
    }

    package mutating func add(_ text: String) {
        add(Data(text.utf8))
    }

    package static func of(_ bytes: Data) -> UInt64 {
        var hash = FNV64()
        hash.add(bytes)
        return hash.value
    }
}

/// Virtual nanoseconds.
package typealias SimTime = UInt64

package extension SimTime {
    static func ms(_ milliseconds: UInt64) -> SimTime { milliseconds * 1_000_000 }
    static func sec(_ seconds: UInt64) -> SimTime { seconds * 1_000_000_000 }
    static func us(_ microseconds: UInt64) -> SimTime { microseconds * 1_000 }
}

/// The scheduler's agenda: a binary heap of `(time, sequence)`, ties in insertion order.
struct Agenda {
    struct Entry {
        var time: SimTime
        var sequence: UInt64
        var action: (SimWorld) -> Void
    }

    private var heap: [Entry] = []
    private var sequence: UInt64 = 0

    var isEmpty: Bool { heap.isEmpty }
    var nextTime: SimTime? { heap.first?.time }

    mutating func push(_ time: SimTime, _ action: @escaping (SimWorld) -> Void) {
        sequence += 1
        heap.append(Entry(time: time, sequence: sequence, action: action))
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard Self.less(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Entry? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, Self.less(heap[left], heap[smallest]) { smallest = left }
            if right < heap.count, Self.less(heap[right], heap[smallest]) { smallest = right }
            guard smallest != parent else { break }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }

    private static func less(_ a: Entry, _ b: Entry) -> Bool {
        a.time != b.time ? a.time < b.time : a.sequence < b.sequence
    }
}

/// Deterministic payloads and their stand-in digests: the core counts bytes only,
/// so the fake installer verifies against this digest instead of SHA-256.
package enum SimPayload {
    package static func content(size: Int, tag: UInt64) -> Data {
        var generator = SplitMix64(seed: tag)
        return generator.bytes(size)
    }

    package static func digest(_ content: Data) -> Data {
        var digest = Data()
        for salt in UInt64(1)...4 {
            var hash = FNV64()
            hash.add(salt)
            hash.add(content)
            var value = hash.value
            for _ in 0..<8 {
                digest.append(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }
        return digest
    }
}
