import Foundation
import Darwin
import SwiftProtobuf

/// Convenience alias for the generated top-level wire message.
public typealias Frame = Kernova_V1_Frame

/// A bidirectional Kernova-protocol channel layered on a SOCK_STREAM file descriptor.
///
/// Reads run via `FileHandle.readabilityHandler` on a background GCD queue and are
/// emitted on `incoming`; `send` is synchronous and serialized so concurrent calls
/// cannot interleave on the wire. The channel owns the descriptor and closes it.
/// Keep `writeLock` and `stateLock` separate: `writeFramed` parks in a blocking
/// `write(2)` while the peer's receive buffer is full, and one shared lock would
/// starve the inbound acks that advance the credit window and unblock that write.
public final class VsockChannel: @unchecked Sendable {
    /// Inbound frames.
    ///
    /// The stream finishes on EOF and finishes-with-error on
    /// any framing or decoding failure.
    public let incoming: AsyncThrowingStream<Frame, Error>

    private let fileHandle: FileHandle
    private let continuation: AsyncThrowingStream<Frame, Error>.Continuation

    /// Serializes the blocking `fileHandle.write` call inside `writeFramed`.
    ///
    /// Held only around the write itself — never across a `stateLock`-guarded
    /// check or teardown — so a parked write can't stall anything but other
    /// writers.
    private let writeLock = NSLock()

    /// Guards `started`/`closed`.
    ///
    /// Never held across a blocking call, so the inbound decode path never waits
    /// on a writer parked in `write(2)`.
    private let stateLock = NSLock()
    private var started = false
    private var closed = false

    /// Decodes inbound bytes into frames.
    ///
    /// Fed and drained only from `handleChunk`, which always runs on the
    /// `FileHandle`'s own serial readability GCD queue — reader-confined, no
    /// lock needed.
    private var decoder = VsockFrameDecoder()

    /// Ignores `SIGPIPE` process-wide so a write to a peer whose read side has
    /// closed surfaces as `EPIPE` rather than killing the process.
    ///
    /// Backstop for the per-fd `SO_NOSIGPIPE` set in `init`, which does not take
    /// effect on every path: CI on macOS-26.3 VMs still delivers `SIGPIPE` with
    /// the socket option set.
    private static let suppressSIGPIPEOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Wraps the given file descriptor.
    ///
    /// The descriptor must be a connected
    /// SOCK_STREAM endpoint; the channel will close it on teardown.
    public init(fileDescriptor: Int32) {
        _ = Self.suppressSIGPIPEOnce

        // Per-fd safety net alongside `suppressSIGPIPEOnce`. Best-effort: a
        // `setsockopt` failure here surfaces via the next write's error.
        var nosigpipe: Int32 = 1
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &nosigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        self.fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        let (stream, continuation) = AsyncThrowingStream<Frame, Error>.makeStream()
        self.incoming = stream
        self.continuation = continuation
    }

    deinit {
        // Without this, dropping the last reference without calling `close()`
        // would hang `incoming` consumers forever. `close()` is idempotent.
        close()
    }

    /// Begins reading from the underlying descriptor (idempotent).
    public func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !started, !closed else { return }
        started = true

        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.handleChunk(data)
        }
    }

    /// Encodes and sends a frame.
    ///
    /// Concurrent calls are safe — they serialize on an internal lock.
    ///
    /// - Throws: `VsockChannelError.closed` when the channel is closed or has hit
    ///   EOF; `VsockChannelError.write(_)` when the underlying write failed (the
    ///   channel is torn down before the error reaches the caller); or a
    ///   serialization error, in which case the channel stays open.
    public func send(_ frame: Frame) throws {
        try writeFramed(Self.serializeFramed(frame))
    }

    /// Serializes and length-prefixes a frame into wire-ready bytes.
    ///
    /// Pure, not actor-isolated, and leaves the channel untouched, so a caller with
    /// a large payload can run this O(payload) work on a background executor.
    ///
    /// - Throws: a serialization error from `Frame.serializedData()`, or
    ///   `VsockFrameError.frameTooLarge` if the encoded payload exceeds
    ///   `VsockFrame.maxPayloadSize`.
    public static func serializeFramed(_ frame: Frame) throws -> Data {
        try VsockFrame.encode(frame.serializedData())
    }

    /// Writes already-framed bytes to the wire.
    ///
    /// The write counterpart of `serializeFramed(_:)`. Concurrent calls serialize on
    /// an internal write lock and cannot interleave on the wire.
    ///
    /// - Throws: `VsockChannelError.closed` if the channel is closed, or
    ///   `VsockChannelError.write(_)` if the underlying `FileHandle.write`
    ///   failed (the channel is torn down before the error reaches the caller).
    public func writeFramed(_ framed: Data) throws {
        writeLock.lock()
        guard !isClosed else {
            writeLock.unlock()
            throw VsockChannelError.closed
        }

        let writeError: Error?
        do {
            try fileHandle.write(contentsOf: framed)
            writeError = nil
        } catch {
            writeError = error
        }
        // Release the write lock before tearing down: `teardown` shuts the
        // descriptor down and then re-acquires `writeLock` to close it, so
        // it must never run while this call still holds the lock.
        writeLock.unlock()

        if let writeError {
            teardown(finishWith: writeError)
            throw VsockChannelError.write(writeError)
        }
    }

    /// Tears down the channel.
    ///
    /// Subsequent `send` calls throw `.closed` and
    /// the `incoming` stream finishes (without error).
    public func close() {
        teardown(finishWith: nil)
    }

    private func handleChunk(_ chunk: Data) {
        // Holds `stateLock` across the whole decode/yield loop below, not just this
        // check, so a concurrent `teardown` can't finish `continuation` out from
        // under an in-flight `yield`. Safe because decode/yield never blocks.
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }

        guard !chunk.isEmpty else {
            stateLock.unlock()
            teardown(finishWith: nil)
            return
        }

        decoder.feed(chunk)
        do {
            while let payload = try decoder.nextFrame() {
                let frame = try Frame(serializedBytes: payload)
                continuation.yield(frame)
            }
            stateLock.unlock()
        } catch {
            stateLock.unlock()
            teardown(finishWith: error)
        }
    }

    /// `true` once the channel is closed (locally, by EOF, or by a write/decode failure).
    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    /// Idempotent teardown, safe to call from any context.
    ///
    /// Callers include `writeFramed`'s catch block and `handleChunk`, neither of
    /// which holds `writeLock` at the call point.
    ///
    /// Order matters: `shutdown(2)` runs *before* `writeLock` is acquired, so a
    /// writer parked in `fileHandle.write` is woken and unwinds instead of pinning
    /// the lock forever. Only once that write has unwound is the descriptor closed,
    /// so the fd number isn't reclaimed while a write against it is in flight.
    private func teardown(finishWith error: Error?) {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()

        fileHandle.readabilityHandler = nil
        shutdown(fileHandle.fileDescriptor, SHUT_RDWR)

        writeLock.lock()
        try? fileHandle.close()
        writeLock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

/// Errors raised by `VsockChannel`.
public enum VsockChannelError: Error, Sendable {
    /// `send` was called after the channel was closed (locally or by EOF).
    case closed

    /// The underlying `FileHandle.write` failed. The channel is torn down before
    /// this error reaches the caller — subsequent `send` calls throw `.closed`.
    /// The associated error preserves the original cause.
    case write(any Error)
}

extension VsockChannelError: Equatable {
    /// Compares two errors by case only.
    ///
    /// `.write` cases are equal regardless of the wrapped error; callers needing
    /// the exact cause should inspect the associated value directly.
    public static func == (lhs: VsockChannelError, rhs: VsockChannelError) -> Bool {
        switch (lhs, rhs) {
        case (.closed, .closed): return true
        case (.write, .write): return true
        default: return false
        }
    }
}

// MARK: - Convenience helpers

extension VsockChannel {
    /// Constructs and sends a Kernova V1 Error frame on this channel.
    ///
    /// - Parameters:
    ///   - code: stable machine-readable code, e.g. `"clipboard.format.unavailable"`
    ///   - message: human-readable detail; surfaced in logs
    ///   - inReplyTo: the request type this error replies to, e.g.
    ///     `"clipboard.request"`. When `nil` the field is omitted from the frame and
    ///     `hasInReplyTo` reads `false` on the receiving side.
    /// - Throws: forwards any error from ``send(_:)``.
    public func sendErrorFrame(code: String, message: String, inReplyTo: String?) throws {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.error = Kernova_V1_Error.with {
            $0.code = code
            $0.message = message
            if let inReplyTo { $0.inReplyTo = inReplyTo }
        }
        try send(frame)
    }
}
