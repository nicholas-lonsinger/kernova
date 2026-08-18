import CryptoKit
import Darwin
import Foundation

/// Why a transfer's data connection stopped.
public enum ClipboardDataConnectionError: Error, Equatable {
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

/// The 33 bytes every data connection ends with: how the payload ended, and —
/// when it ended cleanly — the SHA-256 that proves it arrived intact.
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
        /// value. The spelling is the peer's, so it is kept as written.
        case aborted(rawCode: String)
    }

    /// Total size on the wire: one kind byte plus 32 bytes of digest or code.
    public static let byteCount = 33

    /// Bytes after the kind byte.
    private static let bodyByteCount = byteCount - 1

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
        case .aborted(let rawCode):
            bytes[0] = 1
            let body = Array(rawCode.utf8.prefix(Self.bodyByteCount))
            bytes.replaceSubrange(1..<(1 + body.count), with: body)
        }
        return bytes
    }

    /// Reads a trailer out of exactly ``byteCount`` bytes, or `nil` when they
    /// are not a well-formed one.
    public static func parse(_ bytes: Data) -> ClipboardTransferTrailer? {
        guard bytes.count == byteCount else { return nil }
        let body = Data(bytes.dropFirst())
        switch bytes[bytes.startIndex] {
        case 0:
            return ClipboardTransferTrailer(ending: .complete(digest: body))
        case 1:
            let code = String(decoding: body.prefix(while: { $0 != 0 }), as: UTF8.self)
            guard !code.isEmpty else { return nil }
            return ClipboardTransferTrailer(ending: .aborted(rawCode: code))
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
    /// peer from making this side buffer toward `VsockFrame.maxPayloadSize`
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
        let prefix = try readExactly(fd: fd, count: VsockFrame.lengthPrefixSize)
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

    /// Writes the 33-byte trailer that ends the payload.
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
    /// A `ClipboardTransferReply` refusing a transfer outright.
    static func clipboardTransferRefusal(
        transferID: UInt64, code: ClipboardStreamAbortCode, message: String
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardTransferReply = Kernova_V1_ClipboardTransferReply.with {
            $0.transferID = transferID
            $0.refusalCode = code.rawValue
            $0.refusalMessage = message
        }
        return frame
    }
}

// MARK: - Payload writer

/// Hashes and writes one transfer's payload bytes onto its data connection.
///
/// The digest is taken over exactly the bytes handed to the socket, which is
/// what the trailer declares and the receiver checks — the only corruption
/// detector this transport has (docs/CLIPBOARD.md §7).
///
/// `beforeWrite` runs on the writing thread ahead of each socket write, so a
/// supersession or a cancellation is honored between writes rather than only
/// between payloads; throwing from it stops the payload where it stands.
public final class ClipboardPayloadWriter: @unchecked Sendable {
    private let fd: Int32
    private let clock: any EngineClock
    private let beforeWrite: (@Sendable () throws -> Void)?

    private let lock = NSLock()
    private var hasher = SHA256()
    private var written = 0
    private var socketSeconds: TimeInterval = 0
    private var firstByte: EngineInstant?
    private var firstFailure: Error?

    /// Creates a writer for `fd`.
    public init(
        fd: Int32, clock: any EngineClock = makePlatformEngineClock(),
        beforeWrite: (@Sendable () throws -> Void)? = nil
    ) {
        self.fd = fd
        self.clock = clock
        self.beforeWrite = beforeWrite
    }

    /// Payload bytes written so far.
    public var byteCount: Int { lock.withLock { written } }

    /// Seconds summed over every socket write — the time the peer's receive
    /// buffer held this side up.
    public var socketWait: TimeInterval { lock.withLock { socketSeconds } }

    /// When the first payload byte was handed to the socket.
    public var firstByteInstant: EngineInstant? { lock.withLock { firstByte } }

    /// The first failure a write reported, if any.
    ///
    /// A driver that hands this writer to a codec must consult it rather than
    /// trust the codec's own result: AppleArchive can return normally over a
    /// stream callback whose write failed, which would hand out a silently
    /// truncated payload as a complete one.
    public var failure: Error? { lock.withLock { firstFailure } }

    /// The SHA-256 over every payload byte written so far.
    public func digest() -> Data { lock.withLock { Data(hasher.finalize()) } }

    /// Writes `data` whole.
    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    /// Writes `buffer` whole.
    public func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard !buffer.isEmpty else { return }
        try beforeWrite?()
        let startedAt = clock.now
        do {
            try ClipboardDataConnection.write(fd: fd, buffer)
        } catch {
            lock.withLock { if firstFailure == nil { firstFailure = error } }
            throw error
        }
        let finishedAt = clock.now
        lock.withLock {
            hasher.update(bufferPointer: buffer)
            written += buffer.count
            socketSeconds += startedAt.seconds(to: finishedAt)
            if firstByte == nil { firstByte = finishedAt }
        }
    }
}

// MARK: - Payload reader

/// Reads one transfer's payload bytes off its data connection, holding the last
/// ``ClipboardTransferTrailer/byteCount`` back so the trailer never reaches the
/// consumer, and hashing every byte as it is released.
///
/// The lag is what lets the payload and its ending share one byte stream: the
/// consumer sees a payload that ends at exactly the right place, and whatever
/// is left when the stream ends is the trailer — or, if there is less of it,
/// proof the connection was cut short.
///
/// `@unchecked Sendable`: the buffered bytes belong to whichever thread is
/// reading — one, by construction — while the running count and digest carry a
/// lock, since a transfer reports them from wherever it finishes.
public final class ClipboardPayloadReader: @unchecked Sendable {
    private let fd: Int32
    private let bufferBytes: Int
    private let onRelease: (@Sendable (Int) -> Void)?

    private let lock = NSLock()
    private var pending = Data()
    private var atEnd = false
    private var hasher = SHA256()
    private var released = 0

    /// Creates a reader for `fd`.
    ///
    /// - Parameters:
    ///   - fd: the connected socket.
    ///   - bufferBytes: how much is taken off the socket at a time, which is
    ///     also the cadence `onRelease` fires at.
    ///   - onRelease: called with the cumulative payload byte count each time
    ///     bytes are released to the consumer.
    public init(
        fd: Int32, bufferBytes: Int = ClipboardStreamTuning.dataReadBufferBytes,
        onRelease: (@Sendable (Int) -> Void)? = nil
    ) {
        self.fd = fd
        self.bufferBytes = max(1, bufferBytes)
        self.onRelease = onRelease
    }

    /// Payload bytes released so far.
    public var byteCount: Int { lock.withLock { released } }

    /// The SHA-256 over every payload byte released so far.
    public func digest() -> Data { lock.withLock { Data(hasher.finalize()) } }

    /// Releases up to `buffer.count` payload bytes, returning 0 once the stream
    /// has ended and only the trailer is left.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let destination = buffer.baseAddress, !buffer.isEmpty else { return 0 }
        while true {
            if let run = try take(upTo: buffer.count) {
                run.withUnsafeBytes { raw in
                    guard let source = raw.baseAddress else { return }
                    destination.copyMemory(from: source, byteCount: raw.count)
                }
                return run.count
            }
            if atEnd { return 0 }
            try fill()
        }
    }

    /// Releases exactly `count` payload bytes.
    ///
    /// - Throws: ``ClipboardDataConnectionError/truncated`` when the stream ends
    ///   with fewer than `count` payload bytes left.
    public func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        // Reserve toward the count so the buffer grows in one allocation rather
        // than geometric reallocations, but cap it: the count comes from a
        // peer-declared size, which must not force an unbounded up-front
        // allocation. Past the cap the buffer still grows geometrically.
        result.reserveCapacity(min(count, ClipboardStreamTuning.maxInlineReserveBytes))
        while result.count < count {
            guard let run = try take(upTo: count - result.count) else {
                guard !atEnd else { throw ClipboardDataConnectionError.truncated }
                try fill()
                continue
            }
            result.append(run)
        }
        return result
    }

    /// Releases and discards whatever payload is left, refusing a peer that
    /// streams more than `allowance` past the point the consumer stopped.
    public func drain(allowance: Int) throws {
        var discarded = 0
        while true {
            guard let run = try take(upTo: bufferBytes) else {
                if atEnd { return }
                try fill()
                continue
            }
            discarded += run.count
            guard discarded <= allowance else {
                throw ClipboardDataConnectionError.trailingSurplus
            }
        }
    }

    /// The trailer that ended the stream, once every payload byte has been
    /// taken.
    ///
    /// - Throws: ``ClipboardDataConnectionError/truncated`` when the stream
    ///   ended without a well-formed trailer — the peer died, or its connection
    ///   was reset.
    public func trailer() throws -> ClipboardTransferTrailer {
        while !atEnd { try fill() }
        guard let trailer = ClipboardTransferTrailer.parse(pending) else {
            throw ClipboardDataConnectionError.truncated
        }
        return trailer
    }

    // MARK: - Private

    /// Takes up to `count` releasable bytes, or `nil` when none are available
    /// yet.
    private func take(upTo count: Int) throws -> Data? {
        let releasable = pending.count - ClipboardTransferTrailer.byteCount
        guard releasable > 0, count > 0 else { return nil }
        let taken = Data(pending.prefix(min(count, releasable)))
        pending = Data(pending.dropFirst(taken.count))
        lock.withLock {
            hasher.update(data: taken)
            released += taken.count
        }
        onRelease?(byteCount)
        return taken
    }

    /// Takes one buffer off the socket, latching end of stream.
    private func fill() throws {
        guard !atEnd else { return }
        var block = Data(count: bufferBytes)
        let got = try block.withUnsafeMutableBytes { raw in
            try ClipboardDataConnection.read(fd: fd, into: raw)
        }
        guard got > 0 else {
            atEnd = true
            return
        }
        pending.append(block.prefix(got))
    }
}
