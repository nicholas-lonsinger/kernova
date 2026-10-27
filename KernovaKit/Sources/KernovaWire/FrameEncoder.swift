#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Lays frames out for the transport. It checks nothing a frame's type rules
/// forbid; what may be sent is the caller's to decide.
public enum FrameEncoder {
    /// The frame as two writes: its 10-byte header, then its payload, which is
    /// passed through uncopied (and may be empty).
    public static func encode(_ frame: Frame) -> [Data] {
        guard let length = UInt32(exactly: frame.payload.count) else {
            preconditionFailure("A frame payload of \(frame.payload.count) bytes does not fit the 32-bit length field")
        }
        let id = frame.streamID.rawValue
        let header = Data([
            UInt8(truncatingIfNeeded: id >> 24), UInt8(truncatingIfNeeded: id >> 16),
            UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id),
            frame.type.rawValue, frame.flags.rawValue,
            UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
        ])
        return [header, frame.payload]
    }
}
