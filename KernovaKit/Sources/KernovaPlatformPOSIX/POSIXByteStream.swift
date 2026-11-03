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

// Apple's Dispatch marks `DispatchQueue` `Sendable`; swift-corelibs-libdispatch does not, though dispatch
// objects are thread-safe on every platform.
#if canImport(Darwin)
import Dispatch
#else
@preconcurrency import Dispatch
#endif
import KernovaAgentRuntime
import KernovaSynchronization

/// A `ByteStream` over a connected stream socket in non-blocking mode, waiting through `SocketReadiness`
/// whenever the socket is not ready. The host's streams to its guests, and the Linux agent's stream to the host.
///
/// A write to a socket the far side closed fails with `EPIPE` and never raises SIGPIPE: Darwin sets
/// `SO_NOSIGPIPE` on the socket, Linux passes `MSG_NOSIGNAL` to each `sendmsg`.
public final class POSIXByteStream: ByteStream {
    private let descriptor: Int32
    private let readiness: SocketReadiness
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
        var registration: SocketReadiness.Registration?
        /// Between a `.received` and `readMore()`, and once the read side ended.
        var readSuspended = false
        var pendingWrite: PendingWrite?
        var endDelivered = false
        var isShutDown = false
        /// The registration's cancel and the shutdown delivery still to run before the descriptor closes.
        var releasesOutstanding = 0
        var buffer = [UInt8](repeating: 0, count: ByteStreamLimits.maxReceive)
    }

    /// Takes ownership of `descriptor`, a connected stream socket, and puts it in non-blocking,
    /// close-on-exec mode, so no child process the agent execs inherits the connection. Throws the OS's
    /// error, closing nothing, when the descriptor is not a socket or refuses either mode, or when
    /// `SocketReadiness` cannot start.
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
        readiness = try SocketReadiness.shared()
        self.descriptor = descriptor
        self.released = released
        state = Locked(State())
    }

    /// Begins reading on `queue`, where every read, readiness and completion runs.
    public func start(on queue: DispatchQueue, _ handler: @escaping @Sendable (ByteStreamEvent) -> Void) {
        let shutBeforeStart = state.withLock { state -> Bool in
            precondition(state.queue == nil, "a stream started twice")
            state.queue = queue
            guard !state.isShutDown else { return true }
            state.handler = handler
            state.registration = readiness.register(descriptor, queue: queue) { [self] ready in
                if ready.contains(.read) { readReady() }
                if ready.contains(.write) { writeReady() }
            }
            return false
        }
        queue.async { [self] in
            if shutBeforeStart { handler(.ended(.failed(.shutDown))) } else { readReady() }
        }
    }

    /// Reads again after a `.received`.
    public func readMore() {
        let queue = state.withLock { state -> DispatchQueue? in
            guard state.readSuspended, !state.endDelivered, !state.isShutDown else { return nil }
            state.readSuspended = false
            return state.queue
        }
        queue?.async { [self] in readReady() }
    }

    /// Sends at once, on the caller's thread, what the socket accepts, and the rest on the start queue as it
    /// drains; completes on the start queue.
    public func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void) {
        let refused = state.withLock { state -> (DispatchQueue, ByteStreamError)? in
            guard let queue = state.queue else { preconditionFailure("a write before start") }
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

    /// Shuts the socket both ways, cancels the registration, and closes the descriptor once the registration
    /// no longer watches it and the final deliveries have run.
    public func shutdown() {
        let actions = state.withLock { state -> (DispatchQueue?, @Sendable () -> Void)? in
            guard !state.isShutDown else { return nil }
            state.isShutDown = true
            Glue.shutdownSocket(descriptor)
            guard let queue = state.queue, let registration = state.registration else {
                close(descriptor)
                return (nil, { [released] in released?() })
            }
            registration.cancel { [self] in release() }
            state.releasesOutstanding = 2
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

    // MARK: Reading and writing

    /// Reads once, waiting for readiness when the socket has nothing yet.
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
                state.registration?.arm(.read)
                return nil
            } else {
                event = .ended(.failed(.system(read.error)))
            }
            state.readSuspended = true
            if case .ended = event { state.endDelivered = true }
            return (event, handler)
        }
        if let (event, handler) = event { handler(event) }
    }

    /// Writes what the pending write still holds, waiting for readiness when the socket takes no more;
    /// completes it once written or failed.
    private func writeReady() {
        let next = state.withLock { state -> (DispatchQueue, @Sendable () -> Void)? in
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
            guard failure != nil || pending.index == pending.chunks.count else {
                state.pendingWrite = pending
                state.registration?.arm(.write)
                return nil
            }
            state.pendingWrite = nil
            let completion = pending.completion
            let result = failure
            return (queue, { completion(result) })
        }
        guard let (queue, completion) = next else { return }
        queue.async(execute: completion)
    }

    /// The registration's cancel or the shutdown delivery ran; the last closes the descriptor and drops the
    /// handler and registration, after the lock is released, then reports the release.
    private func release() {
        let dropped = state.withLock { state -> (Any?, Any?)? in
            state.releasesOutstanding -= 1
            guard state.releasesOutstanding == 0 else { return nil }
            close(descriptor)
            defer {
                state.handler = nil
                state.registration = nil
            }
            return (state.handler, state.registration)
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
