import CryptoKit
import Darwin
import Foundation
import KernovaKit

// Driving one transfer's data connection by hand, from whichever side a test is
// standing in for. A real connection carries, in order: one header frame from
// the initiator, the sender's `ClipboardTransferReply`, the payload bytes, a
// 33-byte trailer, then EOF.

// MARK: - Opening a connection

/// Makes a socketpair, hands the far end to `peer` on a thread of its own, and
/// returns this side's descriptor to whoever dialled.
///
/// Stands in for a vsock dial: the caller gets a connected descriptor, and
/// whatever plays the peer takes the other end off the caller's thread, exactly
/// as an accept on a listener would.
///
/// A peer stand-in parks in a blocking read for as long as its case needs, so it
/// gets a thread of its own rather than one of GCD's global queue's, which a
/// parallel bundle is already drawing on.
public func dialToPeer(_ peer: @escaping @Sendable (Int32) -> Void) throws -> Int32 {
    let (near, far) = try makeRawSocketPair()
    Thread.detachNewThread { peer(far) }
    return near
}

/// The peer ends of the data connections a dialling side has opened, oldest
/// first.
///
/// A transfer dials from its own queue, so a test awaits its connection here
/// rather than racing the dial. Hand ``dialer`` to whatever is under test and
/// take each connection with ``next()``.
public final class DialledDataConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [Int32] = []
    private var taken = 0
    private let gate = AsyncGate()

    /// Creates an empty collector.
    public init() {}

    /// The dialler to hand over: each call records one connection's far end and
    /// returns the near end to the caller.
    public var dialer: @Sendable (UInt32) throws -> Int32 {
        { [self] _ in
            let (near, far) = try makeRawSocketPair()
            add(far)
            return near
        }
    }

    /// Records one dialled connection's peer end.
    public func add(_ fd: Int32) {
        lock.withLock { opened.append(fd) }
        gate.notify()
    }

    /// How many connections have been dialled so far.
    public var count: Int { lock.withLock { opened.count } }

    /// The next connection nothing has taken, awaiting one that has not been
    /// dialled yet.
    public func next(isolation: isolated (any Actor)? = #isolation) async throws -> Int32 {
        try await gate.wait(isolation: isolation) {
            self.lock.withLock { self.opened.count > self.taken }
        }
        return lock.withLock {
            let fd = opened[taken]
            taken += 1
            return fd
        }
    }

    /// Closes every connection nothing took, so a torn-down test leaks none.
    public func closeAll() {
        let leftover = lock.withLock { () -> [Int32] in
            let rest = Array(opened[taken...])
            taken = opened.count
            return rest
        }
        for fd in leftover { ClipboardDataConnection.end(fd: fd) }
    }
}

// MARK: - Reading the header

/// The `ClipboardTransferRequest` a dialling receiver opens with, or `nil` when
/// the connection carried something else.
public func readTransferRequest(fd: Int32) -> Kernova_V1_ClipboardTransferRequest? {
    guard let frame = try? ClipboardDataConnection.readFrame(fd: fd),
        case .clipboardTransferRequest(let request) = frame.payload
    else { return nil }
    return request
}

/// The `ClipboardTransferReply` a sending peer opens with, or `nil` when the
/// connection carried something else.
public func readTransferReply(fd: Int32) -> Kernova_V1_ClipboardTransferReply? {
    guard let frame = try? ClipboardDataConnection.readFrame(fd: fd),
        case .clipboardTransferReply(let reply) = frame.payload
    else { return nil }
    return reply
}

// MARK: - Standing in for the sender

/// Serves one whole transfer: the reply describing the payload, the payload, a
/// completion trailer over exactly those bytes, then EOF.
///
/// `declaredBytes` defaults to what the real sender declares — the payload's own
/// size for raw bytes, `0` for an archive, whose compressed size it cannot know
/// up front — and is overridable so a test can declare a size the payload does
/// not match.
public func serveTransfer(
    fd: Int32, transferID: UInt64, payload: Data, isArchive: Bool, isInline: Bool,
    declaredBytes: Int? = nil
) throws {
    defer { ClipboardDataConnection.end(fd: fd) }
    try ClipboardDataConnection.writeFrame(
        makeTransferReplyFrame(
            transferID: transferID, isArchive: isArchive, isInline: isInline,
            totalBytes: declaredBytes ?? (isArchive ? 0 : payload.count)),
        fd: fd)
    try writeTransferBytes(fd: fd, payload)
    try ClipboardDataConnection.writeTrailer(
        ClipboardTransferTrailer(ending: .complete(digest: sha256(payload))), fd: fd)
}

/// Serves a transfer that stops part-way: the reply, `sent` payload bytes, then
/// an abort trailer naming `code`, then EOF.
///
/// `declaredBytes` is what the reply advertises, so the receiver is left short
/// of the payload it was promised and reads the trailer for the reason.
public func abortTransfer(
    fd: Int32, transferID: UInt64, code: String, isArchive: Bool = false, isInline: Bool = true,
    sent: Data = Data(), declaredBytes: Int = 1
) throws {
    defer { ClipboardDataConnection.end(fd: fd) }
    try ClipboardDataConnection.writeFrame(
        makeTransferReplyFrame(
            transferID: transferID, isArchive: isArchive, isInline: isInline,
            totalBytes: isArchive ? 0 : declaredBytes),
        fd: fd)
    try writeTransferBytes(fd: fd, sent)
    try ClipboardDataConnection.writeTrailer(
        ClipboardTransferTrailer(ending: .aborted(rawCode: code)), fd: fd)
}

/// Refuses a transfer outright: a reply naming `code`, no payload, no trailer.
public func refuseTransfer(
    fd: Int32, transferID: UInt64, code: String, message: String = "refused"
) throws {
    defer { ClipboardDataConnection.end(fd: fd) }
    try ClipboardDataConnection.writeFrame(
        makeTransferRefusalFrame(transferID: transferID, code: code, message: message), fd: fd)
}

// MARK: - Standing in for the receiver

/// One whole transfer as the receiving side read it off the wire.
public struct ReceivedTransfer: Sendable {
    /// The descriptor the payload followed.
    public let reply: Kernova_V1_ClipboardTransferReply
    /// Every payload byte, trailer excluded.
    public let payload: Data
    /// How the payload ended, or `nil` when the stream was cut short of a
    /// well-formed trailer.
    public let trailer: ClipboardTransferTrailer?

    /// Whether the transfer ended cleanly with a digest matching its payload.
    public var isComplete: Bool {
        guard case .complete(let digest)? = trailer?.ending else { return false }
        return digest == sha256(payload)
    }

    /// The abort code the trailer named, if it aborted.
    public var abortCode: String? {
        guard case .aborted(let rawCode)? = trailer?.ending else { return nil }
        return rawCode
    }
}

/// Reads one whole transfer off `fd` — the reply, the payload and the trailer —
/// and closes it.
///
/// Buffers the payload whole, so it is for a fixture-sized transfer.
public func receiveTransfer(fd: Int32) throws -> ReceivedTransfer {
    defer { ClipboardDataConnection.end(fd: fd) }
    let frame = try ClipboardDataConnection.readFrame(fd: fd)
    guard case .clipboardTransferReply(let reply) = frame.payload else {
        throw TestFailure("A data connection opened with \(String(describing: frame.payload))")
    }
    var rest = try readToEnd(fd: fd)
    guard rest.count >= ClipboardTransferTrailer.byteCount else {
        return ReceivedTransfer(reply: reply, payload: rest, trailer: nil)
    }
    let trailerBytes = Data(rest.suffix(ClipboardTransferTrailer.byteCount))
    rest = Data(rest.dropLast(ClipboardTransferTrailer.byteCount))
    return ReceivedTransfer(
        reply: reply, payload: rest, trailer: ClipboardTransferTrailer.parse(trailerBytes))
}

/// Opens a transfer as the dialling receiver does — a request naming it, then
/// the reply, the payload and the trailer.
public func pullTransfer(
    fd: Int32, generation: UInt64, transferID: UInt64, uti: String,
    maxAcceptByteCount: UInt64 = .max
) throws -> ReceivedTransfer {
    try ClipboardDataConnection.writeFrame(
        makeTransferRequestFrame(
            generation: generation, transferID: transferID, uti: uti,
            maxAcceptByteCount: maxAcceptByteCount),
        fd: fd)
    return try receiveTransfer(fd: fd)
}

// MARK: - Bytes

/// `count` bytes following `(i * multiplier + offset) mod 256` — a fixed,
/// incompressible-enough pattern built with a plain loop, so no test carries a
/// closure the type checker has to unpick.
public func patternedBytes(count: Int, multiplier: Int, offset: Int) -> Data {
    var bytes = Data(count: count)
    for index in 0..<count {
        bytes[index] = UInt8(truncatingIfNeeded: index &* multiplier &+ offset)
    }
    return bytes
}

/// The SHA-256 a completion trailer carries over a payload.
public func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

/// Writes every byte of `data` to `fd`.
public func writeTransferBytes(fd: Int32, _ data: Data) throws {
    guard !data.isEmpty else { return }
    try data.withUnsafeBytes { raw in
        guard var cursor = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let wrote = Darwin.write(fd, cursor, remaining)
            if wrote > 0 {
                cursor = cursor.advanced(by: wrote)
                remaining -= wrote
                continue
            }
            if wrote < 0, errno == EINTR { continue }
            throw TestFailure("write() on a data connection failed: errno=\(errno)")
        }
    }
}

/// Reads `fd` to end of stream.
public func readToEnd(fd: Int32) throws -> Data {
    var collected = Data()
    var block = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let got = block.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
        if got > 0 {
            collected.append(contentsOf: block[..<got])
            continue
        }
        if got == 0 { return collected }
        if errno == EINTR { continue }
        throw TestFailure("read() on a data connection failed: errno=\(errno)")
    }
}
