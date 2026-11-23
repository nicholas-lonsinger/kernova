#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

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
