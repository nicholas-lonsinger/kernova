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
    /// Floor below which the consumed prefix is never compacted, so small
    /// buffers don't churn on a shift.
    ///
    /// This is only the floor: `compactIfNeeded` also requires the consumed
    /// prefix to be at least as large as the unread tail before shifting, so
    /// each surviving byte is copied at most once before it is dropped and the
    /// buffer stays within ~2× the live (unread) bytes.
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
    /// - Returns: The payload (without the length prefix) of the next frame, as
    ///   a slice aliasing the decoder's buffer — consume it before the next
    ///   `feed`/`nextFrame` (see the `RATIONALE` in the body) — or `nil` if the
    ///   buffer does not yet hold a complete frame.
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
        // RATIONALE: return a slice that aliases `buffer` rather than copying the
        // payload out — this removes the per-frame payload copy on the common path
        // (#377). On the amortized-rare frames where `compactIfNeeded` shifts, the
        // still-live slice turns that shift into a copy-on-write; the net is still a
        // win because most frames don't compact. The slice shares the decoder's
        // backing storage, so a caller MUST consume (or copy) it before the next
        // `feed`/
        // `nextFrame` mutates the decoder; the sole production consumer,
        // `VsockChannel.handleChunk`, parses each payload synchronously via
        // `Frame(serializedBytes:)` inside its decode loop and never lets the raw
        // slice cross the `incoming` async boundary. `Data`'s copy-on-write keeps
        // this correct even if a future caller does stash the slice — the next
        // buffer mutation simply COWs — so the invariant is a performance contract,
        // not a safety one. The slice carries a non-zero `startIndex`; index it
        // through its own indices, not absolute offsets.
        let payload = buffer[payloadStart..<payloadEnd]
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

    /// Two-tier compaction of the consumed prefix.
    ///
    /// Drained buffers reset without a shift; partial buffers shift only once the
    /// consumed prefix reaches both `compactionThreshold` and the size of the
    /// unread tail, so a shift never moves more bytes than it reclaims (amortized
    /// O(1) per byte). Either branch copy-on-writes when a just-returned payload
    /// slice still aliases the buffer (see `nextFrame`).
    private mutating func compactIfNeeded() {
        guard readOffset > 0 else { return }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            return
        }
        // RATIONALE: gate the shift on `readOffset >= unread`, not just the fixed
        // threshold. A chunk frame is ~65.5 KiB — already past `compactionThreshold`
        // on its own — so a bare `readOffset >= compactionThreshold` guard would
        // memmove the entire unread tail after *every* frame, moving far more than
        // it reclaims and breaking the "each byte copied at most once" invariant
        // (#377). Requiring the reclaimable prefix to be at least the tail size
        // keeps the amortized copy cost O(1) at the price of the buffer growing to
        // ~2× the live bytes (window-bounded to a few MiB) between compactions.
        let unread = buffer.count - readOffset
        if readOffset >= max(VsockFrameDecoder.compactionThreshold, unread) {
            let unreadStart = buffer.startIndex + readOffset
            buffer.removeSubrange(buffer.startIndex..<unreadStart)
            readOffset = 0
        }
    }
}
