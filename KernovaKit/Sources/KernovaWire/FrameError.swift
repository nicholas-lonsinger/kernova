/// What a frame header alone shows is wrong. Every case is fatal to the connection.
public enum FrameError: Error, Equatable, Sendable {
    /// The first 4 bytes are not `WireConstants.preamble`: the far side does not
    /// speak this protocol.
    case badPreamble
    /// A `type` byte above `FrameType.ping`.
    case unknownType(UInt8)
    /// A flags byte, as received, holding a bit the frame's type does not define.
    case undefinedFlags(FrameType, UInt8)
    /// A `length` over the type's maximum.
    case payloadTooLarge(FrameType, declared: UInt32)
    /// A WINDOW or PING whose `length` is not its fixed size.
    case wrongFixedLength(FrameType, declared: UInt32)
    /// A raw DATA frame with no payload.
    case emptyRawData

    /// The code the RESET on stream 0 carries; nil for `.badPreamble`, which closes
    /// the transport with no RESET.
    public var closeCode: ErrorCode? {
        switch self {
        case .badPreamble: nil
        case .payloadTooLarge: .frameTooLarge
        case .unknownType, .undefinedFlags, .wrongFixedLength, .emptyRawData: .protocolError
        }
    }
}
