#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch
// does not, though dispatch objects are thread-safe on every platform.
#if canImport(Darwin)
import Dispatch
#else
@preconcurrency import Dispatch
#endif
import KernovaAgentRuntime
import KernovaSynchronization

/// A `ByteStream` over a connected stream socket in non-blocking mode, driven by dispatch read and write
/// sources on the start queue. The host's, Linux guests' and macOS 15+ guests' streams.
///
/// A write to a socket the far side closed fails with `EPIPE` and never raises SIGPIPE: Darwin sets
/// `SO_NOSIGPIPE` on the socket, Linux passes `MSG_NOSIGNAL` to each `sendmsg`.
public final class POSIXByteStream: ByteStream {
    private let descriptor: Int32
    private let released: (@Sendable () -> Void)?
    private let state: Locked<State>

    private struct PendingWrite: Sendable {
        var chunks: [Data]
        /// The chunk the next byte comes from, and the offset within it.
        var index = 0
        var offset = 0
        var completion: @Sendable (ByteStreamError?) -> Void
    }

    private struct State: Sendable {
        var queue: DispatchQueue?
        var handler: (@Sendable (ByteStreamEvent) -> Void)?
        var readSource: (any DispatchSourceRead)?
        var writeSource: (any DispatchSourceWrite)?
        /// Suspended between a `.received` and `readMore()`, and once the read side ended.
        var readSuspended = false
        var writeSuspended = true
        var pendingWrite: PendingWrite?
        var endDelivered = false
        var isShutDown = false
        /// The cancel handlers and the shutdown delivery still to run before the descriptor closes.
        var releasesOutstanding = 0
        var buffer = [UInt8](repeating: 0, count: ByteStreamLimits.maxReceive)
    }

    /// Takes ownership of `descriptor`, a connected stream socket, and puts it in non-blocking,
    /// close-on-exec mode, so no child process the agent execs inherits the connection. Throws the OS's
    /// error, closing nothing, when the descriptor is not a socket or refuses either mode.
    ///
    /// `released` runs once the descriptor is closed and the stream holds nothing more: on the start queue
    /// after `shutdown()`, or inside `shutdown()` when the stream was never started.
    public init(adopting descriptor: Int32, released: (@Sendable () -> Void)? = nil) throws(ByteStreamError) {
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &length) == 0 else { throw .system(errno) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw .system(errno) }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0, fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            throw .system(errno)
        }
        #if canImport(Darwin)
        var on: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw .system(errno) }
        #endif
        self.descriptor = descriptor
        self.released = released
        state = Locked(State())
    }

    /// Begins reading on `queue`; the read and write sources run there.
    public func start(on queue: DispatchQueue, _ handler: @escaping @Sendable (ByteStreamEvent) -> Void) {
        let shutBeforeStart = state.withLock { state -> Bool in
            precondition(state.queue == nil, "a stream started twice")
            state.queue = queue
            guard !state.isShutDown else { return true }
            state.handler = handler
            let read = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            let write = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            read.setEventHandler { [self] in readReady() }
            write.setEventHandler { [self] in writeReady() }
            read.setCancelHandler { [self] in release() }
            write.setCancelHandler { [self] in release() }
            state.readSource = read
            state.writeSource = write
            read.activate()
            return false
        }
        if shutBeforeStart { queue.async { handler(.ended(.failed(.shutDown))) } }
    }

    /// Resumes the read source after a `.received`.
    public func readMore() {
        state.withLock { state in
            guard state.readSuspended, !state.endDelivered, !state.isShutDown else { return }
            state.readSuspended = false
            state.readSource?.resume()
        }
    }

    /// Writes at once what the socket accepts and the rest as it drains; completes on the start queue.
    public func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void) {
        let refused = state.withLock { state -> (DispatchQueue, ByteStreamError)? in
            guard let queue = state.queue else { return nil }
            if state.isShutDown { return (queue, .shutDown) }
            precondition(state.pendingWrite == nil, "a second write while one is outstanding")
            state.pendingWrite = PendingWrite(chunks: chunks.filter { !$0.isEmpty }, completion: completion)
            return nil
        }
        if let (queue, error) = refused {
            return queue.async { completion(error) }
        }
        writeReady()
    }

    /// Shuts the socket both ways, cancels the sources, and closes the descriptor once both cancel
    /// handlers and the final deliveries have run.
    public func shutdown() {
        let actions = state.withLock { state -> (DispatchQueue?, @Sendable () -> Void)? in
            guard !state.isShutDown else { return nil }
            state.isShutDown = true
            Glue.shutdownSocket(descriptor)
            guard let queue = state.queue, let read = state.readSource, let write = state.writeSource else {
                close(descriptor)
                return (nil, { [released] in released?() })
            }
            read.cancel()
            write.cancel()
            if state.readSuspended {
                state.readSuspended = false
                read.resume()
            }
            if state.writeSuspended {
                state.writeSuspended = false
                write.resume()
            }
            state.releasesOutstanding = 3
            let completion = state.pendingWrite?.completion
            state.pendingWrite = nil
            let handler = state.endDelivered ? nil : state.handler
            state.endDelivered = true
            return (
                queue,
                { [self] in
                    completion?(.shutDown)
                    handler?(.ended(.failed(.shutDown)))
                    release()
                }
            )
        }
        guard let (queue, deliver) = actions else { return }
        if let queue { queue.async(execute: deliver) } else { deliver() }
    }

    // MARK: Source handlers, on the start queue

    private func readReady() {
        let event = state.withLock { state -> (ByteStreamEvent, @Sendable (ByteStreamEvent) -> Void)? in
            guard !state.isShutDown, !state.endDelivered, !state.readSuspended, let handler = state.handler
            else { return nil }
            let read = state.buffer.withUnsafeMutableBytes { buffer in
                let count = recv(descriptor, buffer.baseAddress, buffer.count, 0)
                return (count: count, error: count < 0 ? errno : 0)
            }
            let event: ByteStreamEvent
            if read.count > 0 {
                event = .received(Data(state.buffer[0..<read.count]))
            } else if read.count == 0 {
                event = .ended(.eof)
            } else if read.error == EAGAIN || read.error == EWOULDBLOCK || read.error == EINTR {
                return nil
            } else {
                event = .ended(.failed(.system(read.error)))
            }
            state.readSuspended = true
            state.readSource?.suspend()
            if case .ended = event { state.endDelivered = true }
            return (event, handler)
        }
        if let (event, handler) = event { handler(event) }
    }

    /// Writes what the pending write still holds; completes it once written or failed.
    private func writeReady() {
        let finished = state.withLock { state -> (DispatchQueue, @Sendable () -> Void)? in
            guard !state.isShutDown, var pending = state.pendingWrite, let queue = state.queue else { return nil }
            var failure: ByteStreamError?
            while pending.index < pending.chunks.count {
                let sent = Glue.send(descriptor, pending.chunks, from: pending.index, offset: pending.offset)
                if sent.count < 0 {
                    if sent.error == EINTR { continue }
                    if sent.error == EAGAIN || sent.error == EWOULDBLOCK { break }
                    failure = .system(sent.error)
                    break
                }
                var remaining = sent.count
                while remaining > 0 {
                    let left = pending.chunks[pending.index].count - pending.offset
                    if remaining >= left {
                        remaining -= left
                        pending.index += 1
                        pending.offset = 0
                    } else {
                        pending.offset += remaining
                        remaining = 0
                    }
                }
            }
            let done = failure != nil || pending.index == pending.chunks.count
            if done {
                state.pendingWrite = nil
                if !state.writeSuspended {
                    state.writeSuspended = true
                    state.writeSource?.suspend()
                }
                let completion = pending.completion
                let result = failure
                return (queue, { completion(result) })
            }
            state.pendingWrite = pending
            if state.writeSuspended {
                state.writeSuspended = false
                state.writeSource?.resume()
            }
            return nil
        }
        if let (queue, complete) = finished { queue.async(execute: complete) }
    }

    /// One of the two cancel handlers or the shutdown delivery ran; the last closes the descriptor and
    /// drops the handler and sources, after the lock is released, then reports the release.
    private func release() {
        let dropped = state.withLock { state -> (Any?, Any?, Any?)? in
            state.releasesOutstanding -= 1
            guard state.releasesOutstanding == 0 else { return nil }
            close(descriptor)
            defer {
                state.handler = nil
                state.readSource = nil
                state.writeSource = nil
            }
            return (state.handler, state.readSource, state.writeSource)
        }
        guard dropped != nil else { return }
        released?()
    }
}

/// The calls whose spelling differs between Darwin and Linux.
private enum Glue {
    static func shutdownSocket(_ descriptor: Int32) {
        _ = shutdown(descriptor, Int32(SHUT_RDWR))
    }

    /// `sendmsg` of up to 64 chunks from `index`, the first from `offset`, and the `errno` it set; never
    /// raises SIGPIPE.
    static func send(_ descriptor: Int32, _ chunks: [Data], from index: Int, offset: Int) -> (count: Int, error: Int32)
    {
        var vectors: [iovec] = []
        vectors.reserveCapacity(64)
        return pin(chunks[index..<min(chunks.count, index + 64)], offset: offset, &vectors) { vectors in
            var message = msghdr()
            message.msg_iov = vectors.baseAddress
            message.msg_iovlen = numericCast(vectors.count)
            #if canImport(Darwin)
            let count = sendmsg(descriptor, &message, 0)
            #else
            let count = sendmsg(descriptor, &message, Int32(MSG_NOSIGNAL))
            #endif
            return (count, count < 0 ? errno : 0)
        }
    }

    /// Calls `body` with one iovec per chunk — non-empty, the first starting at `offset` — each pinned for
    /// the call.
    private static func pin<Result>(
        _ chunks: ArraySlice<Data>, offset: Int, _ vectors: inout [iovec],
        _ body: (UnsafeMutableBufferPointer<iovec>) -> Result
    ) -> Result {
        guard let first = chunks.first else {
            return vectors.withUnsafeMutableBufferPointer { body($0) }
        }
        return first.withUnsafeBytes { bytes in
            vectors.append(
                iovec(
                    iov_base: bytes.baseAddress.map { UnsafeMutableRawPointer(mutating: $0 + offset) },
                    iov_len: bytes.count - offset))
            return pin(chunks.dropFirst(), offset: 0, &vectors, body)
        }
    }
}
#endif
