import Foundation
import Darwin
import SwiftProtobuf

/// Convenience alias for the generated top-level wire message.
public typealias Frame = Kernova_V1_Frame

/// A bidirectional Kernova-protocol channel layered on a SOCK_STREAM file descriptor.
///
/// Reads run via `FileHandle.readabilityHandler` on a background GCD queue;
/// decoded frames are emitted on the `incoming` async stream. Writes are
/// synchronous from the caller's perspective and serialized by an internal
/// lock so concurrent `send` calls cannot interleave on the wire.
///
/// The channel takes ownership of the file descriptor: it will be closed by
/// `close()`, by EOF on the read side, or by the underlying `FileHandle` on
/// dealloc.
///
/// **Concurrency model**: this class is `@unchecked Sendable` with an
/// internal `NSLock` rather than `@MainActor`-isolated like much of the
/// host-side code (`SpiceClipboardService`, `VsockGuestLogService`). The
/// reasons:
/// - `FileHandle.readabilityHandler` callbacks run on a private GCD queue,
///   not main, so consuming them through actor isolation would require
///   bouncing every chunk through `await MainActor.run`
/// - `VsockChannel` is consumed by both host (`@MainActor` services) and
///   the guest agent (top-level main.swift code that's nonisolated), so
///   pinning to a specific actor would force one of them through extra
///   hops
/// The lock-based design lets either side call `send` from any context and
/// drain `incoming` from any task without isolation hops.
public final class VsockChannel: @unchecked Sendable {
    /// Inbound frames.
    ///
    /// The stream finishes on EOF and finishes-with-error on
    /// any framing or decoding failure.
    public let incoming: AsyncThrowingStream<Frame, Error>

    private let fileHandle: FileHandle
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<Frame, Error>.Continuation

    // All fields below are protected by `lock`.
    private var decoder = VsockFrameDecoder()
    private var started = false
    private var closed = false

    /// Set once on first `VsockChannel` construction: ignore `SIGPIPE`
    /// process-wide so a write to a peer whose read side has closed surfaces
    /// as `EPIPE` from `write(2)` instead of killing the process.
    ///
    /// Belt-and-suspenders alongside the per-fd `SO_NOSIGPIPE` set in `init` —
    /// `SO_NOSIGPIPE` doesn't appear to take effect on every code path
    /// across macOS versions / `FileHandle` write internals (CI on macOS-26.3
    /// VMs still delivers `SIGPIPE` despite the socket option being set), so
    /// the global handler is the reliable backstop.
    private static let suppressSIGPIPEOnce: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Wraps the given file descriptor.
    ///
    /// The descriptor must be a connected
    /// SOCK_STREAM endpoint; the channel will close it on teardown.
    public init(fileDescriptor: Int32) {
        _ = Self.suppressSIGPIPEOnce

        // Per-fd safety net: when the option does take effect, this is the
        // cleaner mechanism (errors from individual writes vs. a global
        // signal mask change). When it doesn't, `suppressSIGPIPEOnce`
        // already covers us. Best-effort — `setsockopt` failure on a fresh
        // socket is non-fatal and would surface via the next write's error.
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
        // Belt-and-braces: if a caller drops the last strong reference
        // without invoking `close()`, finishing the continuation here
        // prevents `incoming` consumers from hanging forever waiting
        // on a stream whose producer has gone away. Idempotent — `close()`
        // guards against repeat teardown via its own `closed` flag.
        close()
    }

    /// Begins reading from the underlying descriptor (idempotent).
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !closed else { return }
        started = true

        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.handleChunk(data)
        }
    }

    /// Encodes and sends a frame.
    ///
    /// Multiple concurrent calls are safe — they
    /// serialize on an internal lock.
    ///
    /// Errors thrown:
    /// - `VsockChannelError.closed` — channel is locally closed or has hit EOF
    /// - `VsockChannelError.write(_)` — the underlying `FileHandle.write`
    ///   failed; the channel is torn down before the error reaches the caller
    /// - any error from `Frame.serializedData()` / `VsockFrame.encode(_:)`
    ///   if the frame itself is unencodable; in that case the channel
    ///   stays open
    public func send(_ frame: Frame) throws {
        try writeFramed(Self.serializeFramed(frame))
    }

    /// Serializes and length-prefixes a frame into wire-ready bytes.
    ///
    /// Pure and not actor-isolated, so a caller with a large payload can run
    /// this O(payload) work — the protobuf encode plus the `VsockFrame.encode`
    /// copy — on a background executor before handing the result to
    /// `writeFramed(_:)`. The channel is untouched.
    ///
    /// - Throws: a serialization error from `Frame.serializedData()`, or
    ///   `VsockFrameError.frameTooLarge` if the encoded payload exceeds
    ///   `VsockFrame.maxPayloadSize`.
    public static func serializeFramed(_ frame: Frame) throws -> Data {
        try VsockFrame.encode(frame.serializedData())
    }

    /// Writes already-framed bytes to the wire under the channel lock.
    ///
    /// The write counterpart of `serializeFramed(_:)` — callers that serialized
    /// off-actor finish the send here. Like `send`, concurrent calls serialize
    /// on the internal lock and cannot interleave on the wire.
    ///
    /// - Throws: `VsockChannelError.closed` if the channel is closed, or
    ///   `VsockChannelError.write(_)` if the underlying `FileHandle.write`
    ///   failed (the channel is torn down before the error reaches the caller).
    public func writeFramed(_ framed: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw VsockChannelError.closed }

        do {
            try fileHandle.write(contentsOf: framed)
        } catch {
            tearDownLocked(finishWith: error)
            throw VsockChannelError.write(error)
        }
    }

    /// Sends a frame with every O(payload) step off the caller's actor.
    ///
    /// `serializeFramed(_:)` (protobuf encode + framing copy) and the socket
    /// write both run on the cooperative executor, so awaiting this from the
    /// `@MainActor` keeps a large frame send from blocking the UI.
    /// Throws the same errors as `send(_:)`.
    public func sendOffActor(_ frame: Frame) async throws {
        try writeFramed(Self.serializeFramed(frame))
    }

    /// Tears down the channel.
    ///
    /// Subsequent `send` calls throw `.closed` and
    /// the `incoming` stream finishes (without error).
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        tearDownLocked(finishWith: nil)
    }

    private func handleChunk(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        guard !chunk.isEmpty else {
            tearDownLocked(finishWith: nil)
            return
        }

        decoder.feed(chunk)
        do {
            while let payload = try decoder.nextFrame() {
                let frame = try Frame(serializedBytes: payload)
                continuation.yield(frame)
            }
        } catch {
            tearDownLocked(finishWith: error)
        }
    }

    private func tearDownLocked(finishWith error: Error?) {
        closed = true
        fileHandle.readabilityHandler = nil
        try? fileHandle.close()
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

    /// The underlying `FileHandle.write` failed. The channel is torn down
    /// before this error reaches the caller — subsequent `send` calls will
    /// throw `.closed`. The associated error preserves the original cause
    /// (typically a `CocoaError.fileWriteUnknown` wrapping a POSIX errno).
    case write(any Error)

    // RATIONALE: `Equatable` is implemented manually so callers can still
    // pattern-match on `.closed` (the common test case) without forcing
    // every wrapped error to be Equatable. `.write` cases compare equal to
    // each other irrespective of their inner error — sufficient for the
    // type-discrimination use case; if a caller needs the exact underlying
    // error they should switch and inspect the associated value directly.
}

extension VsockChannelError: Equatable {
    /// Compares two errors by case only.
    ///
    /// `.write` cases are equal regardless of the wrapped underlying error;
    /// callers needing the exact cause should switch and inspect the
    /// associated value directly.
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
    /// Convenience wrapper around `send` that centralizes the protocol-version
    /// pin and the optional `inReplyTo` plumbing. Callers that treat error
    /// reporting as best-effort (the typical case — the channel is usually
    /// torn down for the same reason being reported) catch and log at `.debug`.
    ///
    /// Throws any error documented on `send(_:)` — `VsockChannelError.closed`,
    /// `VsockChannelError.write(_)`, or a serialization error from
    /// `Frame.serializedData()` / `VsockFrame.encode(_:)`.
    ///
    /// - Parameters:
    ///   - code: stable machine-readable code, e.g. `"clipboard.format.unavailable"`
    ///   - message: human-readable detail; surfaced in logs
    ///   - inReplyTo: optional ref to the request type this error replies to,
    ///     e.g. `"clipboard.request"`. When `nil`, the field is omitted from
    ///     the encoded frame and `hasInReplyTo` reads `false` on the receiving side.
    /// - Throws: forwards any error from ``send(_:)`` — typically
    ///   ``VsockChannelError/closed`` if the channel is closed, or
    ///   ``VsockChannelError/write(_:)`` if the underlying `FileHandle.write` fails.
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
