import Foundation

/// Length-prefixed framing on top of a byte stream.
///
/// Each frame is a 4-byte big-endian `UInt32` length prefix followed by exactly
/// that many payload bytes. The length value does not include the 4-byte prefix
/// itself.
///
/// Byte-stream transports (vsock SOCK_STREAM, AF_UNIX SOCK_STREAM, pipes) do
/// not preserve message boundaries; this framing layer reintroduces them.
///
/// Use `encode(_:)` on the writer side to produce a self-delimiting frame.
/// Use `VsockFrameDecoder` on the reader side to recover whole frames from a
/// stream of arbitrary chunks.
public enum VsockFrame {

    /// Maximum payload size accepted on the wire, in bytes.
    ///
    /// A peer that announces a larger frame is treated as protocol-violating —
    /// `VsockFrameDecoder.nextFrame()` throws `VsockFrameError.frameTooLarge`
    /// rather than buffer unboundedly.
    public static let maxPayloadSize: Int = 16 * 1024 * 1024

    /// Number of bytes occupied by the length prefix.
    public static let lengthPrefixSize: Int = 4

    /// Returns `payload` prefixed with its big-endian `UInt32` length.
    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxPayloadSize else {
            throw VsockFrameError.frameTooLarge(
                declaredSize: payload.count,
                maxAllowed: maxPayloadSize
            )
        }
        var lengthBE = UInt32(payload.count).bigEndian
        var frame = Data()
        frame.reserveCapacity(lengthPrefixSize + payload.count)
        withUnsafeBytes(of: &lengthBE) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

/// Errors thrown by the framing layer.
public enum VsockFrameError: Error, Sendable, Equatable {
    /// A frame's declared payload size exceeds `VsockFrame.maxPayloadSize`.
    /// The stream is unrecoverable at this point and the caller should close
    /// the connection.
    case frameTooLarge(declaredSize: Int, maxAllowed: Int)
}

/// Reassembles `VsockFrame` payloads from an unframed byte stream.
///
/// Feed arbitrary chunks via `feed(_:)` (a single payload may span any number
/// of chunks; multiple payloads may share one chunk) then drain whole frames
/// with successive `nextFrame()` calls until it returns `nil`.
///
/// The decoder is `Sendable` and intended to be owned by a single actor or
/// queue at a time.
public struct VsockFrameDecoder: Sendable {

    private var buffer: Data = Data()

    public init() {}

    /// Appends raw bytes to the internal buffer. Does not parse.
    public mutating func feed(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// Extracts the next complete frame payload from the buffer, if available.
    ///
    /// - Returns: The payload (without the length prefix) of the next frame,
    ///   or `nil` if the buffer does not yet hold a complete frame.
    /// - Throws: `VsockFrameError.frameTooLarge` if a frame's declared size
    ///   exceeds `VsockFrame.maxPayloadSize`. After this throws, the decoder
    ///   should be discarded — the buffer is left in place but the stream is
    ///   considered corrupt.
    public mutating func nextFrame() throws -> Data? {
        guard buffer.count >= VsockFrame.lengthPrefixSize else { return nil }

        let payloadSize = Int(readLengthPrefix())

        guard payloadSize <= VsockFrame.maxPayloadSize else {
            throw VsockFrameError.frameTooLarge(
                declaredSize: payloadSize,
                maxAllowed: VsockFrame.maxPayloadSize
            )
        }

        let totalFrameSize = VsockFrame.lengthPrefixSize + payloadSize
        guard buffer.count >= totalFrameSize else { return nil }

        let start = buffer.startIndex + VsockFrame.lengthPrefixSize
        let end = buffer.startIndex + totalFrameSize
        let payload = Data(buffer[start..<end])
        buffer.removeSubrange(buffer.startIndex..<end)
        return payload
    }

    /// `true` when no buffered bytes remain.
    public var isEmpty: Bool { buffer.isEmpty }

    /// Number of buffered bytes not yet consumed.
    public var bufferedByteCount: Int { buffer.count }

    private func readLengthPrefix() -> UInt32 {
        buffer.prefix(VsockFrame.lengthPrefixSize).withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
    }
}
