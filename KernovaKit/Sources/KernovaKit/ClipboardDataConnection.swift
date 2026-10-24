import CryptoKit
import Darwin
import Foundation
import KernovaSynchronization

/// Why a transfer's data connection stopped.
enum ClipboardDataConnectionError: Error, Equatable {
    /// The peer closed or reset the connection in the middle of a message.
    case closed
    /// A `read(2)` or `write(2)` reached the socket's own timeout with no bytes
    /// moving — the stall this transport is bounded by.
    case timedOut
    /// The stream ended before its trailer, so what arrived is a prefix of the
    /// payload rather than the payload.
    case truncated
    /// A header frame declares more bytes than a data connection's header may
    /// carry.
    case frameTooLarge(Int)
    /// The header frame is not the one this side expects at this point in the
    /// exchange.
    case unexpectedFrame
    /// The peer kept streaming past the end of a payload this side had already
    /// finished taking.
    case trailingSurplus
    /// The socket reported an error, carrying its `errno`.
    case io(Int32)
}

/// What every data connection ends with: how the payload ended, and — when it
/// ended cleanly — the SHA-256 that proves it arrived intact.
///
/// The last ``byteCount`` bytes are a kind byte and a 32-byte body: the digest
/// for a complete payload; for an abort, the code in the body's first 30 bytes
/// and, in its last two, the big-endian length of a detail that precedes the
/// kind byte — a serialized ``ClipboardItemFailure``, or nothing. A
/// reader finds where the trailer begins from its last bytes alone, which is
/// what lets it hold back at most ``maximumByteCount``.
///
/// Carrying the reason in the byte stream rather than in a control frame is
/// what lets an abort be a plain `shutdown(2)` on the receiving side and a
/// supersession stay silent on the sending side, with no frame racing the
/// bytes it describes.
public struct ClipboardTransferTrailer: Equatable, Sendable {
    /// How the payload ended.
    public enum Ending: Equatable, Sendable {
        /// Every payload byte was written; the SHA-256 over them follows.
        case complete(digest: Data)
        /// The sending side gave up, naming a `ClipboardStreamAbortCode` raw
        /// value — kept as the peer spelled it — and, for a `read.error`, the
        /// item it could not read.
        case aborted(rawCode: String, readFailure: ClipboardItemFailure? = nil)
    }

    /// The fixed tail: one kind byte plus 32 bytes of digest or abort code and
    /// detail length.
    public static let byteCount = 33

    /// The longest a trailer can be: the fixed tail plus the largest detail.
    public static let maximumByteCount = byteCount + ClipboardItemFailure.maximumEncodedByteCount

    /// Bytes after the kind byte.
    private static let bodyByteCount = byteCount - 1

    /// Bytes of an abort's body that carry its code; the rest carry the detail
    /// length.
    private static let abortCodeByteCount = bodyByteCount - 2

    /// How the payload ended.
    public let ending: Ending

    /// Creates a trailer for `ending`.
    public init(ending: Ending) {
        self.ending = ending
    }

    /// The trailer's wire bytes.
    public var encoded: Data {
        var bytes = Data(count: Self.byteCount)
        switch ending {
        case .complete(let digest):
            let body = digest.prefix(Self.bodyByteCount)
            bytes.replaceSubrange(1..<(1 + body.count), with: body)
            return bytes
        case .aborted(let rawCode, let readFailure):
            bytes[0] = 1
            let code = Array(rawCode.utf8.prefix(Self.abortCodeByteCount))
            bytes.replaceSubrange(1..<(1 + code.count), with: code)
            let detail = readFailure?.encoded ?? Data()
            bytes[Self.byteCount - 2] = UInt8(truncatingIfNeeded: detail.count >> 8)
            bytes[Self.byteCount - 1] = UInt8(truncatingIfNeeded: detail.count)
            return detail + bytes
        }
    }

    /// How many of the last bytes of `tail` a well-formed trailer would take,
    /// or `nil` when `tail` cannot end in one.
    ///
    /// Only the fixed tail is read, so this is where a stream's trailer begins
    /// once the stream has ended — not proof that it parses.
    public static func byteCount(endingWith tail: Data) -> Int? {
        guard tail.count >= byteCount else { return nil }
        let fixed = tail.suffix(byteCount)
        guard fixed[fixed.startIndex] == 1 else { return byteCount }
        let detail = Int(fixed[fixed.endIndex - 2]) << 8 | Int(fixed[fixed.endIndex - 1])
        guard detail <= ClipboardItemFailure.maximumEncodedByteCount,
            tail.count >= byteCount + detail
        else { return nil }
        return byteCount + detail
    }

    /// Reads a trailer out of exactly the bytes it takes, or `nil` when they
    /// are not a well-formed one.
    ///
    /// An abort's detail that does not decode leaves its code standing: the
    /// code is what the receiver acts on, and the detail only names the item.
    public static func parse(_ bytes: Data) -> ClipboardTransferTrailer? {
        guard let length = byteCount(endingWith: bytes), length == bytes.count else { return nil }
        let fixed = Data(bytes.suffix(byteCount))
        let body = fixed.dropFirst()
        switch fixed[fixed.startIndex] {
        case 0:
            return ClipboardTransferTrailer(ending: .complete(digest: Data(body)))
        case 1:
            let code = String(
                decoding: body.prefix(abortCodeByteCount).prefix(while: { $0 != 0 }), as: UTF8.self)
            guard !code.isEmpty else { return nil }
            let detail = Data(bytes.prefix(bytes.count - byteCount))
            return ClipboardTransferTrailer(
                ending: .aborted(
                    rawCode: code, readFailure: ClipboardItemFailure(encoded: detail)))
        default:
            return nil
        }
    }
}

/// The wire mechanics of one transfer's vsock data connection: its socket
/// options, its two header frames, its trailer, and the blocking reads and
/// writes everything above is built from.
///
/// Flow control here is the kernel's. `write(2)` parks while the peer's receive
/// buffer is full and wakes as it drains, so nothing above this counts credit;
/// a peer that stops reading costs the host nothing
/// (docs/research/2026-08-17-vsock-stalled-receiver-and-accept-latency.md).
public enum ClipboardDataConnection {
    /// The most a data connection's header frame may declare: 64 KiB.
    ///
    /// A `ClipboardTransferRequest`/`Reply` is tens of bytes; the bound keeps a
    /// peer from making this side buffer toward `StreamFrame.maxPayloadSize`
    /// before the frame is even parsed.
    static let maxHeaderFrameBytes = 64 * 1024

    /// Ignores `SIGPIPE` process-wide so a write to a peer whose read side has
    /// closed surfaces as `EPIPE` rather than killing the process.
    ///
    /// Backstop for the per-fd `SO_NOSIGPIPE` below, which does not take effect
    /// on every path (`VsockChannel` carries the same pair for the same
    /// reason).
    private static let suppressSIGPIPEOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Applies the safety and stall bounds every data connection carries,
    /// whichever end of it `fd` is and whichever direction it will carry.
    ///
    /// Idempotent, so the side that opens the descriptor can bound it before
    /// anything reads on it and the transfer that adopts it can still state its
    /// own `timeout`.
    ///
    /// Best-effort: a `setsockopt` this socket family does not honor changes the
    /// stall bound, never correctness, and surfaces through the next read or
    /// write.
    public static func applySocketOptions(
        fd: Int32, timeout: TimeInterval = ClipboardStreamTuning.dataSocketTimeout
    ) {
        _ = suppressSIGPIPEOnce
        var enabled: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var window = timeval(
            tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Raises `SO_SNDBUF` on an accepted descriptor this side is about to stream
    /// a payload on.
    ///
    /// Both halves of that sentence decide it: an accepted socket is the one
    /// born at 8 KiB, where a dialler has already sized its own, and a send
    /// buffer is only ever spent by the end that sends. Best-effort, as above.
    public static func raiseSendBuffer(fd: Int32) {
        var sendBuffer = Int32(ClipboardStreamTuning.dataSendBufferBytes)
        _ = setsockopt(
            fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Wakes whichever thread is parked in a read or write on `fd`, without
    /// closing it.
    ///
    /// Safe from any thread and idempotent — the cancellation path for a
    /// receiver that owns no other way into a parked `read(2)`.
    public static func interrupt(fd: Int32) {
        _ = shutdown(fd, SHUT_RDWR)
    }

    /// Ends the connection: wakes any parked peer of this fd, then closes it.
    ///
    /// Call once, from the side that owns the descriptor.
    public static func end(fd: Int32) {
        _ = shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }

    // MARK: - Frames

    /// Reads one length-prefixed `Frame`, parking until it has arrived whole.
    ///
    /// - Throws: ``ClipboardDataConnectionError`` — `.closed` when the peer
    ///   ends the connection before the frame is complete, `.unexpectedFrame`
    ///   when the bytes do not decode as a version-1 `Frame`.
    public static func readFrame(fd: Int32) throws -> Frame {
        let prefix = try readExactly(fd: fd, count: StreamFrame.lengthPrefixSize)
        let size = Int(
            prefix.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard size <= maxHeaderFrameBytes else {
            throw ClipboardDataConnectionError.frameTooLarge(size)
        }
        let payload = size > 0 ? try readExactly(fd: fd, count: size) : Data()
        guard let frame = try? Frame(serializedBytes: payload), frame.protocolVersion == 1 else {
            throw ClipboardDataConnectionError.unexpectedFrame
        }
        return frame
    }

    /// Serializes `frame` and writes it whole.
    public static func writeFrame(_ frame: Frame, fd: Int32) throws {
        try write(fd: fd, VsockChannel.serializeFramed(frame))
    }

    /// Writes the trailer that ends the payload.
    public static func writeTrailer(_ trailer: ClipboardTransferTrailer, fd: Int32) throws {
        try write(fd: fd, trailer.encoded)
    }

    // MARK: - Bytes

    /// Reads whatever is available into `buffer`, returning 0 at end of stream.
    static func read(fd: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        while true {
            let got = Darwin.read(fd, buffer.baseAddress, buffer.count)
            if got >= 0 { return got }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK: throw ClipboardDataConnectionError.timedOut
            case ECONNRESET, EPIPE, EBADF, ENOTCONN: throw ClipboardDataConnectionError.closed
            default: throw ClipboardDataConnectionError.io(errno)
            }
        }
    }

    /// Reads exactly `count` bytes, parking until they have all arrived.
    ///
    /// - Throws: `.closed` when the stream ends first.
    static func readExactly(fd: Int32, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data(count: count)
        var filled = 0
        while filled < count {
            let got = try result.withUnsafeMutableBytes { raw -> Int in
                let slice = UnsafeMutableRawBufferPointer(rebasing: raw[filled...])
                return try read(fd: fd, into: slice)
            }
            guard got > 0 else { throw ClipboardDataConnectionError.closed }
            filled += got
        }
        return result
    }

    /// Writes every byte of `data`, parking while the peer's receive buffer is
    /// full.
    static func write(fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { try write(fd: fd, $0) }
    }

    /// Writes every byte of `buffer`, parking while the peer's receive buffer is
    /// full.
    ///
    /// All-or-nothing by contract: AppleArchive never re-offers the tail a
    /// short write left behind, so a partial accept would silently truncate an
    /// archive.
    static func write(fd: Int32, _ buffer: UnsafeRawBufferPointer) throws {
        guard var cursor = buffer.baseAddress else { return }
        var remaining = buffer.count
        while remaining > 0 {
            let wrote = Darwin.write(fd, cursor, remaining)
            if wrote > 0 {
                cursor = cursor.advanced(by: wrote)
                remaining -= wrote
                continue
            }
            guard wrote < 0 else { throw ClipboardDataConnectionError.closed }
            switch errno {
            case EINTR: continue
            case EAGAIN, EWOULDBLOCK: throw ClipboardDataConnectionError.timedOut
            case EPIPE, ECONNRESET, EBADF, ENOTCONN: throw ClipboardDataConnectionError.closed
            default: throw ClipboardDataConnectionError.io(errno)
            }
        }
    }
}

// MARK: - Header frames

extension Frame {
    /// A `ClipboardTransferReply` refusing a transfer outright, naming the item
    /// that could not be read for a `read.error` refusal.
    static func clipboardTransferRefusal(
        transferID: UInt64, code: ClipboardStreamAbortCode, message: String,
        readFailure: ClipboardItemFailure? = nil
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardTransferReply = Kernova_V1_ClipboardTransferReply.with {
            $0.transferID = transferID
            $0.refusalCode = code.rawValue
            $0.refusalMessage = message
            if let readFailure { $0.readFailure = readFailure.wire }
        }
        return frame
    }
}

// MARK: - Payload writer

/// Hashes and writes one transfer's payload bytes onto its data connection.
///
/// The digest is taken over exactly the bytes handed to the socket, which is
/// what the trailer declares and the receiver checks. It is the only corruption
/// detector this transport has: virtio-vsock's packet header carries no
/// checksum — `struct virtio_vsock_hdr` is cids, ports, `len`, `type`, `op`,
/// `flags`, `buf_alloc` and `fwd_cnt` and nothing else
/// (`include/uapi/linux/virtio_vsock.h`).
///
/// `beforeWrite` runs on the writing thread ahead of each socket write, so a
/// supersession or a cancellation is honored between writes rather than only
/// between payloads; throwing from it stops the payload where it stands.
final class ClipboardPayloadWriter {
    private let fd: Int32
    private let clock: any EngineClock
    private let beforeWrite: (@Sendable () throws -> Void)?

    private struct State {
        var hasher = SHA256()
        var written = 0
        var socketSeconds: TimeInterval = 0
        var firstByte: EngineInstant?
        var firstFailure: (any Error)?

        mutating func recordFailure(_ error: any Error) {
            if firstFailure == nil { firstFailure = error }
        }
    }

    /// Written from AppleArchive's worker thread and read from the caller's
    /// after the codec returns, with no ordering documented between them.
    private let state = Locked(State())

    /// Creates a writer for `fd`.
    init(
        fd: Int32, clock: any EngineClock = makePlatformEngineClock(),
        beforeWrite: (@Sendable () throws -> Void)? = nil
    ) {
        self.fd = fd
        self.clock = clock
        self.beforeWrite = beforeWrite
    }

    /// Payload bytes written so far.
    var byteCount: Int { state.withLock { $0.written } }

    /// Seconds summed over every socket write — the time the peer's receive
    /// buffer held this side up.
    var socketWait: TimeInterval { state.withLock { $0.socketSeconds } }

    /// When the first payload byte was handed to the socket.
    var firstByteInstant: EngineInstant? { state.withLock { $0.firstByte } }

    /// The first failure a write reported, if any.
    ///
    /// A driver that hands this writer to a codec must consult it rather than
    /// trust the codec's own result: AppleArchive can return normally over a
    /// stream callback whose write failed, which would hand out a silently
    /// truncated payload as a complete one.
    var failure: (any Error)? { state.withLock { $0.firstFailure } }

    /// The SHA-256 over every payload byte written so far.
    func digest() -> Data { state.withLock { Data($0.hasher.finalize()) } }

    /// Writes `data` whole.
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    /// Writes `buffer` whole.
    func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard !buffer.isEmpty else { return }
        try beforeWrite?()
        let startedAt = clock.now
        do {
            try ClipboardDataConnection.write(fd: fd, buffer)
        } catch {
            state.withLock { $0.recordFailure(error) }
            throw error
        }
        let finishedAt = clock.now
        state.withLock { state in
            state.hasher.update(bufferPointer: buffer)
            state.written += buffer.count
            state.socketSeconds += startedAt.seconds(to: finishedAt)
            if state.firstByte == nil { state.firstByte = finishedAt }
        }
    }
}

// MARK: - Payload reader

/// Reads one transfer's payload bytes off its data connection, holding the last
/// ``ClipboardTransferTrailer/maximumByteCount`` back until the stream ends —
/// and then exactly the trailer its last bytes describe — so the trailer never
/// reaches the consumer, and hashing every byte as it is released.
///
/// The lag is what lets the payload and its ending share one byte stream: the
/// consumer sees a payload that ends at exactly the right place, and whatever
/// is left when the stream ends is the trailer — or, if there is less of it,
/// proof the connection was cut short.
final class ClipboardPayloadReader {
    private let fd: Int32
    private let bufferBytes: Int
    private let onArrival: (@Sendable () -> Void)?
    private let onRelease: (@Sendable (Int) -> Void)?

    /// What one attempt to release payload bytes found.
    private enum Next {
        /// Bytes released, and the payload total released so far.
        case run(Data, released: Int)
        /// The stream has ended; only the trailer is left.
        case ended
        /// Nothing is releasable until more is read off the socket.
        case needsFill
    }

    private struct State {
        var pending = Data()
        var atEnd = false
        var hasher = SHA256()
        var released = 0
        var firstFailure: (any Error)?

        /// Takes up to `count` releasable bytes, hashing what it releases.
        mutating func take(upTo count: Int) -> Next {
            let heldBack =
                atEnd
                ? ClipboardTransferTrailer.byteCount(endingWith: pending)
                    ?? ClipboardTransferTrailer.byteCount
                : ClipboardTransferTrailer.maximumByteCount
            let releasable = pending.count - heldBack
            guard releasable > 0, count > 0 else { return atEnd ? .ended : .needsFill }
            let taken = Data(pending.prefix(min(count, releasable)))
            pending = Data(pending.dropFirst(taken.count))
            hasher.update(data: taken)
            released += taken.count
            return .run(taken, released: released)
        }

        mutating func recordFailure(_ error: any Error) {
            if firstFailure == nil { firstFailure = error }
        }
    }

    /// Read from AppleArchive's worker thread during an extract and from the
    /// caller's after it returns, with no ordering documented between them.
    private let state = Locked(State())

    /// Creates a reader for `fd`.
    ///
    /// - Parameters:
    ///   - fd: the connected socket.
    ///   - bufferBytes: how much is taken off the socket at a time, which is
    ///     also the cadence `onArrival` and `onRelease` fire at.
    ///   - onRelease: called with the cumulative payload byte count each time
    ///     bytes are released to the consumer.
    ///   - onArrival: called each time bytes are taken off the socket, whether
    ///     or not any can be released yet — the trailer's hold-back delays a
    ///     release, never an arrival.
    init(
        fd: Int32, bufferBytes: Int = ClipboardStreamTuning.dataReadBufferBytes,
        onRelease: (@Sendable (Int) -> Void)? = nil,
        onArrival: (@Sendable () -> Void)? = nil
    ) {
        self.fd = fd
        self.bufferBytes = max(1, bufferBytes)
        self.onArrival = onArrival
        self.onRelease = onRelease
    }

    /// Payload bytes released so far.
    var byteCount: Int { state.withLock { $0.released } }

    /// The first failure a read reported, if any.
    ///
    /// A driver that hands this reader to a codec must consult it rather than
    /// trust the codec's own result: AppleArchive rewraps whatever the source
    /// threw, so a connection that timed out under an extract reaches the
    /// driver as an archive failure and would be named one.
    var failure: (any Error)? { state.withLock { $0.firstFailure } }

    /// The SHA-256 over every payload byte released so far.
    func digest() -> Data { state.withLock { Data($0.hasher.finalize()) } }

    /// Releases up to `buffer.count` payload bytes, returning 0 once the stream
    /// has ended and only the trailer is left.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let destination = buffer.baseAddress, !buffer.isEmpty else { return 0 }
        while true {
            switch next(upTo: buffer.count) {
            case .run(let run, _):
                run.withUnsafeBytes { raw in
                    guard let source = raw.baseAddress else { return }
                    destination.copyMemory(from: source, byteCount: raw.count)
                }
                return run.count
            case .ended:
                return 0
            case .needsFill:
                try fill()
            }
        }
    }

    /// Releases exactly `count` payload bytes.
    ///
    /// - Throws: ``ClipboardDataConnectionError/truncated`` when the stream ends
    ///   with fewer than `count` payload bytes left.
    func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        // Reserve toward the count so the buffer grows in one allocation rather
        // than geometric reallocations, but cap it: the count comes from a
        // peer-declared size, which must not force an unbounded up-front
        // allocation. Past the cap the buffer still grows geometrically.
        result.reserveCapacity(min(count, ClipboardStreamTuning.maxInlineReserveBytes))
        while result.count < count {
            switch next(upTo: count - result.count) {
            case .run(let run, _): result.append(run)
            case .ended: throw ClipboardDataConnectionError.truncated
            case .needsFill: try fill()
            }
        }
        return result
    }

    /// Releases and discards whatever payload is left, refusing a peer that
    /// streams more than `allowance` past the point the consumer stopped.
    func drain(allowance: Int) throws {
        var discarded = 0
        while true {
            switch next(upTo: bufferBytes) {
            case .run(let run, _):
                discarded += run.count
                guard discarded <= allowance else {
                    throw ClipboardDataConnectionError.trailingSurplus
                }
            case .ended:
                return
            case .needsFill:
                try fill()
            }
        }
    }

    /// The trailer that ended the stream, once every payload byte has been
    /// taken.
    ///
    /// - Throws: ``ClipboardDataConnectionError/truncated`` when the stream
    ///   ended without a well-formed trailer — the peer died, or its connection
    ///   was reset.
    func trailer() throws -> ClipboardTransferTrailer {
        while true {
            let parsed = state.withLock { state -> ClipboardTransferTrailer?? in
                guard state.atEnd else { return nil }
                return .some(ClipboardTransferTrailer.parse(state.pending))
            }
            guard let parsed else {
                try fill()
                continue
            }
            guard let trailer = parsed else { throw ClipboardDataConnectionError.truncated }
            return trailer
        }
    }

    // MARK: - Private

    /// Takes up to `count` releasable bytes, reporting a release to
    /// `onRelease`.
    private func next(upTo count: Int) -> Next {
        let next = state.withLock { $0.take(upTo: count) }
        if case .run(_, let released) = next { onRelease?(released) }
        return next
    }

    /// Takes one buffer off the socket, latching end of stream.
    ///
    /// Called only once the stream is known not to have ended: one thread
    /// reads at a time, and only a read latches the end.
    private func fill() throws {
        var block = Data(count: bufferBytes)
        let got: Int
        do {
            got = try block.withUnsafeMutableBytes { raw in
                try ClipboardDataConnection.read(fd: fd, into: raw)
            }
        } catch {
            state.withLock { $0.recordFailure(error) }
            throw error
        }
        state.withLock { state in
            if got > 0 {
                state.pending.append(block.prefix(got))
            } else {
                state.atEnd = true
            }
        }
        if got > 0 { onArrival?() }
    }
}
