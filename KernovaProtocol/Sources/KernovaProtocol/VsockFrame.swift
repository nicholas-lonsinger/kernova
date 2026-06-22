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
enum VsockFrame {
    /// Maximum payload size accepted on the wire, in bytes.
    ///
    /// A peer that announces a larger frame is treated as protocol-violating —
    /// `VsockFrameDecoder.nextFrame()` throws `VsockFrameError.frameTooLarge`
    /// rather than buffer unboundedly.
    ///
    /// Clipboard data is now chunk-streamed: each `ClipboardChunk` is a normal
    /// frame whose payload is at most the negotiated chunk size (64 KiB by
    /// default), so no single frame approaches this ceiling. It survives purely
    /// as a DoS backstop — the ceiling on how much a single peer-declared frame
    /// length can make the receiver buffer before the frame is parsed. 128 MiB
    /// leaves generous headroom over the largest control/log frame while still
    /// bounding that envelope; untrusted-guest hardening is tracked in #145.
    static let maxPayloadSize: Int = 128 * 1024 * 1024

    /// Number of bytes occupied by the length prefix.
    static let lengthPrefixSize: Int = 4

    /// Returns `payload` prefixed with its big-endian `UInt32` length.
    static func encode(_ payload: Data) throws -> Data {
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
enum VsockFrameError: Error, Sendable, Equatable {
    /// A frame's declared payload size exceeds `VsockFrame.maxPayloadSize`.
    /// On the decode side the stream is unrecoverable at this point and the
    /// caller should close the connection.
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
struct VsockFrameDecoder: Sendable {
    /// Compact the consumed prefix once the read offset crosses this many
    /// bytes.
    ///
    /// Sized to amortize the shift cost (each byte is copied at most
    /// once before being dropped) without keeping more than ~64 KiB of stale
    /// storage live per decoder.
    private static let compactionThreshold: Int = 64 * 1024

    private var buffer: Data = Data()
    private var readOffset: Int = 0

    /// Creates an empty decoder ready to accept bytes via `feed(_:)`.
    init() {}

    /// Appends raw bytes to the internal buffer (does not parse).
    mutating func feed(_ chunk: Data) {
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
    mutating func nextFrame() throws -> Data? {
        let unread = buffer.count - readOffset
        guard unread >= VsockFrame.lengthPrefixSize else { return nil }

        let payloadSize = Int(readLengthPrefix())

        guard payloadSize <= VsockFrame.maxPayloadSize else {
            throw VsockFrameError.frameTooLarge(
                declaredSize: payloadSize,
                maxAllowed: VsockFrame.maxPayloadSize
            )
        }

        let totalFrameSize = VsockFrame.lengthPrefixSize + payloadSize
        guard unread >= totalFrameSize else { return nil }

        let payloadStart = buffer.startIndex + readOffset + VsockFrame.lengthPrefixSize
        let payloadEnd = buffer.startIndex + readOffset + totalFrameSize
        let payload = Data(buffer[payloadStart..<payloadEnd])
        readOffset += totalFrameSize

        compactIfNeeded()
        return payload
    }

    /// `true` when no buffered bytes remain.
    var isEmpty: Bool { buffer.count == readOffset }

    /// Number of buffered bytes not yet consumed.
    var bufferedByteCount: Int { buffer.count - readOffset }

    private func readLengthPrefix() -> UInt32 {
        let start = buffer.startIndex + readOffset
        let end = start + VsockFrame.lengthPrefixSize
        return buffer[start..<end].withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
    }

    /// Two-tier compaction: drained buffers reset for free; partial buffers
    /// shift only after the threshold to keep the per-byte copy cost amortized.
    private mutating func compactIfNeeded() {
        guard readOffset > 0 else { return }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            return
        }
        if readOffset >= VsockFrameDecoder.compactionThreshold {
            let unreadStart = buffer.startIndex + readOffset
            buffer.removeSubrange(buffer.startIndex..<unreadStart)
            readOffset = 0
        }
    }
}
