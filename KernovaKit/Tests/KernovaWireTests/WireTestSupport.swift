#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// SplitMix64: the same bytes for the same seed on every platform.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count {
                buffer[index] = UInt8(truncatingIfNeeded: next())
            }
        }
        return data
    }
}

/// The preamble, then each frame's encoded bytes.
func wireBytes(_ frames: [Frame], preamble: Bool = true) -> Data {
    var data = preamble ? WireConstants.preamble : Data()
    for frame in frames {
        for part in FrameEncoder.encode(frame) {
            data.append(part)
        }
    }
    return data
}

/// A header with arbitrary field bytes, for headers no `Frame` can express.
func rawHeader(stream: UInt32 = 1, type: UInt8, flags: UInt8 = 0, length: UInt32) -> Data {
    Data([
        UInt8(truncatingIfNeeded: stream >> 24), UInt8(truncatingIfNeeded: stream >> 16),
        UInt8(truncatingIfNeeded: stream >> 8), UInt8(truncatingIfNeeded: stream),
        type, flags,
        UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
        UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
    ])
}

/// Every frame the chunks decode to, appending each chunk and draining after it.
func decodeAll(_ chunks: [Data]) throws(FrameError) -> [Frame] {
    var decoder = FrameDecoder()
    var frames: [Frame] = []
    for chunk in chunks {
        decoder.append(chunk)
        while let frame = try decoder.nextFrame() {
            frames.append(frame)
        }
    }
    return frames
}

extension Data {
    /// `self` cut at each of `offsets`, which are ascending and within bounds.
    func split(at offsets: [Int]) -> [Data] {
        var pieces: [Data] = []
        var start = startIndex
        for offset in offsets {
            pieces.append(self[start..<(startIndex + offset)])
            start = startIndex + offset
        }
        pieces.append(self[start..<endIndex])
        return pieces
    }
}
