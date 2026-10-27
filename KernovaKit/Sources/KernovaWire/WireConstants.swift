#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The fixed numbers of the generation-2 transport and frame layout.
public enum WireConstants {
    /// The 4 bytes each side writes first, ASCII `KRN2`.
    public static let preamble = Data([0x4B, 0x52, 0x4E, 0x32])

    /// Bytes in every frame header: stream id, type, flags, length.
    public static let headerByteCount = 10

    /// The largest raw DATA payload.
    public static let maxRawDataPayload = 1_048_576

    /// The largest payload of a MESSAGE DATA, OPEN, END or RESET frame.
    public static let maxControlPayload = 65_536

    /// The exact payload size of a WINDOW frame: one big-endian `UInt32`.
    public static let windowPayloadByteCount = 4

    /// The exact payload size of a PING frame.
    public static let pingPayloadByteCount = 8

    /// The largest a stream or connection window may reach, 2^31 − 1.
    public static let maxWindow: UInt32 = 2_147_483_647

    /// The longest a side may go without sending a PING: 5 s, in nanoseconds.
    public static let maxPingIntervalNanoseconds: Int64 = 5_000_000_000

    /// The host's vsock port; the guest dials it at host CID 2.
    public static let vsockPort: UInt32 = 49160
}
