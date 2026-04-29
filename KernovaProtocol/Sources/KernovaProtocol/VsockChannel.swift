import Foundation
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
public final class VsockChannel: @unchecked Sendable {

    /// Inbound frames. The stream finishes on EOF and finishes-with-error on
    /// any framing or decoding failure.
    public let incoming: AsyncThrowingStream<Frame, Error>

    private let fileHandle: FileHandle
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<Frame, Error>.Continuation

    // All fields below are protected by `lock`.
    private var decoder = VsockFrameDecoder()
    private var started = false
    private var closed = false

    /// Wraps the given file descriptor. The descriptor must be a connected
    /// SOCK_STREAM endpoint; the channel will close it on teardown.
    public init(fileDescriptor: Int32) {
        self.fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        let (stream, continuation) = AsyncThrowingStream<Frame, Error>.makeStream()
        self.incoming = stream
        self.continuation = continuation
    }

    /// Begins reading from the underlying descriptor. Idempotent.
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

    /// Encodes and sends a frame. Multiple concurrent calls are safe — they
    /// serialize on an internal lock.
    public func send(_ frame: Frame) throws {
        let payload = try frame.serializedData()
        let framed = try VsockFrame.encode(payload)

        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw VsockChannelError.closed }

        do {
            try fileHandle.write(contentsOf: framed)
        } catch {
            tearDownLocked(finishWith: error)
            throw error
        }
    }

    /// Tears down the channel. Subsequent `send` calls throw `.closed` and
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
public enum VsockChannelError: Error, Sendable, Equatable {
    /// `send` was called after the channel was closed (locally or by EOF).
    case closed
}
