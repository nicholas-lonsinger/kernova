#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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
