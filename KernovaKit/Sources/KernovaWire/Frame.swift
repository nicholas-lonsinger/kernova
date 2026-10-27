#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A stream's id within one connection. The host opens even ids, peers odd.
public struct StreamID: RawRepresentable, Hashable, Comparable, Sendable {
    /// The id as it travels in the header.
    public var rawValue: UInt32

    /// Creates the id `rawValue` names.
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Stream 0, the session stream, open for the connection's life.
    public static let session = StreamID(rawValue: 0)

    /// Orders ids by their raw value.
    public static func < (lhs: StreamID, rhs: StreamID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A frame's `type` byte.
public enum FrameType: UInt8, Sendable {
    /// Raw bytes, or one protobuf message under `FrameFlags.message`.
    case data = 0
    /// Opens a stream; the payload is an `Open`.
    case open
    /// Ends this side of a stream; the payload is the kind's END message, or empty.
    case end
    /// Cancels a stream, or on stream 0 closes the connection; the payload is an `Error`.
    case reset
    /// A big-endian `UInt32` credit increment; stream 0 is the connection window.
    case window
    /// 8 opaque bytes on stream 0, ignored by the receiver.
    case ping
}

/// A frame's `flags` byte.
public struct FrameFlags: OptionSet, Hashable, Sendable {
    /// The byte as it travels in the header.
    public var rawValue: UInt8

    /// Creates the flag set `rawValue` holds.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// On DATA: the payload is exactly one whole protobuf message of the stream's kind.
    public static let message = FrameFlags(rawValue: 0x01)
}

/// One frame: a header's fields and its payload.
public struct Frame: Sendable, Equatable {
    /// The stream the frame belongs to.
    public var streamID: StreamID
    /// What the frame is.
    public var type: FrameType
    /// The frame's flags.
    public var flags: FrameFlags
    /// The payload. A decoded raw DATA payload of 64 KiB or more may be a slice of
    /// the chunk it arrived in, so its indices need not start at 0.
    public var payload: Data

    /// Creates a frame from its fields.
    public init(streamID: StreamID, type: FrameType, flags: FrameFlags = [], payload: Data = Data()) {
        self.streamID = streamID
        self.type = type
        self.flags = flags
        self.payload = payload
    }
}
