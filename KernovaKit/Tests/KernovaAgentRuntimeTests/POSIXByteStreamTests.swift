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

import Dispatch
import KernovaAgentRuntime
import KernovaPlatformPOSIX
import KernovaSynchronization
import Testing

/// A raw socket pair: the stream adopts one end and the test drives the other with blocking calls.
enum RawSocket {
    /// A connected pair; `sendBuffer` sizes the first end's send buffer.
    static func pair(sendBuffer: Int32? = nil) throws -> (stream: Int32, far: Int32) {
        var descriptors: [Int32] = [0, 0]
        // Glibc imports SOCK_STREAM as an enum case; Darwin and Musl as an Int32.
        #if canImport(Glibc)
        let paired = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors)
        #else
        let paired = socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors)
        #endif
        guard paired == 0 else { throw ByteStreamError.system(errno) }
        if var size = sendBuffer {
            _ = setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        return (descriptors[0], descriptors[1])
    }

    /// A datagram socket connected to a loopback port nothing listens on, after one send: the port-unreachable
    /// reply leaves an error pending on it with nothing to read and no hang-up — the poll state a Linux vsock is
    /// left in when its transport resets (`virtio_vsock_reset_sock` sets `sk_err` and nothing else `vsock_poll`
    /// reads as readable).
    static func refusedDatagram() throws -> Int32 {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        // Glibc imports SOCK_DGRAM as an enum case; Darwin and Musl as an Int32.
        #if canImport(Glibc)
        let datagram = Int32(SOCK_DGRAM.rawValue)
        #else
        let datagram = SOCK_DGRAM
        #endif
        // A port the kernel picked and then freed, so nothing listens on it: the probe closes before the send.
        try { () throws(ByteStreamError) in
            let probe = socket(AF_INET, datagram, 0)
            guard probe >= 0 else { throw .system(errno) }
            defer { close(probe) }
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    bind(probe, pointer, length) == 0 && getsockname(probe, pointer, &length) == 0
                }
            }
            guard bound else { throw .system(errno) }
        }()
        let descriptor = socket(AF_INET, datagram, 0)
        guard descriptor >= 0 else { throw ByteStreamError.system(errno) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) == 0 }
        }
        var byte: UInt8 = 0
        guard connected, write(descriptor, &byte, 1) == 1 else {
            let error = errno
            close(descriptor)
            throw ByteStreamError.system(error)
        }
        return descriptor
    }

    /// Writes all of `bytes`, blocking.
    static func send(_ descriptor: Int32, _ bytes: Data) {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, bytes.count - offset) }
            guard sent > 0 else { return }
            offset += sent
        }
    }

    /// Reads, blocking, until the far end closes; `chunk` bytes at a time.
    static func readToEnd(_ descriptor: Int32, chunk: Int = 65_536) -> Data {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return bytes }
            bytes.append(contentsOf: buffer[0..<count])
        }
    }

    /// Reads, blocking, exactly `total` bytes in reads of varying size.
    static func read(_ descriptor: Int32, total: Int) -> Data {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 7_919)
        var step = 0
        while bytes.count < total {
            step += 1
            let want = min(total - bytes.count, 1 + (step * 1_009) % buffer.count)
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, want, 0) }
            guard count > 0 else { return bytes }
            bytes.append(contentsOf: buffer[0..<count])
        }
        return bytes
    }
}

/// A started stream with everything it delivers and the moment it releases its descriptor recorded.
final class ObservedStream: Sendable {
    let queue = DispatchQueue(label: "app.kernova.tests.posix")
    let events = Recorder<ByteStreamEvent>()
    let released = Recorder<Int>()
    let stream: POSIXByteStream

    init(adopting descriptor: Int32, start: Bool = true) throws {
        let released = released
        stream = try POSIXByteStream(adopting: descriptor) { released.record(1) }
        if start {
            let events = events
            stream.start(on: queue) { events.record($0) }
        }
    }

    /// Writes `chunks` and waits for the completion, checking it never runs inside the call. The write is
    /// issued from a block on the start queue that marks its own end, so on that serial queue the
    /// completion can find the mark unset only if `write` ran it synchronously.
    func write(_ chunks: [Data], then follow: @escaping @Sendable () -> Void = {}) async
        -> (error: ByteStreamError?, insideCall: Bool)
    {
        let returned = Locked(false)
        let done = Recorder<(ByteStreamError?, Bool)>()
        queue.async { [stream] in
            stream.write(chunks) { error in done.record((error, !returned.withLock { $0 })) }
            returned.withLock { $0 = true }
            follow()
        }
        var waiter = done.waiter()
        return await waiter.next { _ in true }
    }

    func waitForRelease() async {
        var waiter = released.waiter()
        _ = await waiter.next { _ in true }
    }
}

/// The suites that open descriptors, run one test at a time so no test reuses a number another just closed.
@Suite("Sockets", .serialized)
enum SocketTests {}

extension SocketTests {
    @Suite("POSIX byte stream")
    struct POSIXByteStreamTests {
        @Test("More than 64 chunks of mixed sizes, some empty, cross a 4 KiB send buffer byte for byte")
        func manyChunksArriveIntact() async throws {
            let (local, far) = try RawSocket.pair(sendBuffer: 4_096)
            let observed = try ObservedStream(adopting: local)
            let sizes = [0, 1, 17, 4_093, 65_536, 0, 100_003, 9, 3, 131_072, 511]
            let base = FakePayloadSource.payload(140_000)
            let chunks = (0..<220).map { index in
                let start = (index * 7_919) % 8_000
                return Data(base[start..<(start + sizes[index % sizes.count])])
            }
            let expected = chunks.reduce(into: Data()) { $0.append($1) }
            let received = Recorder<Data>()
            DispatchQueue.global().async { received.record(RawSocket.read(far, total: expected.count)) }

            let result = await observed.write(chunks)
            #expect(result.error == nil)
            #expect(!result.insideCall)
            var waiter = received.waiter()
            let bytes = await waiter.next { _ in true }
            #expect(bytes == expected)
            observed.stream.shutdown()
            await observed.waitForRelease()
            close(far)
        }

        @Test("shutdown() from another thread fails a pending write and delivers one .ended(.failed(.shutDown))")
        func shutdownFailsPendingWrite() async throws {
            let (local, far) = try RawSocket.pair(sendBuffer: 4_096)
            let observed = try ObservedStream(adopting: local)
            let result = await observed.write([Data(count: 1_048_576)]) {
                DispatchQueue.global().async { observed.stream.shutdown() }
            }
            #expect(result.error == .shutDown)
            #expect(!result.insideCall)
            await observed.waitForRelease()
            #expect(observed.events.elements == [.ended(.failed(.shutDown))])
            _ = RawSocket.readToEnd(far)
            close(far)
        }

        @Test("shutdown() before start closes the descriptor at once: the far side reads EOF and no handler runs")
        func shutdownBeforeStart() async throws {
            let (local, far) = try RawSocket.pair()
            let observed = try ObservedStream(adopting: local, start: false)
            observed.stream.shutdown()
            await observed.waitForRelease()
            // No other suite opens a descriptor while this one runs (`SocketTests` is serialized), so the number
            // cannot have been reused.
            let flags = fcntl(local, F_GETFD)
            let error = errno
            #expect(flags == -1 && error == EBADF)
            #expect(RawSocket.readToEnd(far).isEmpty)
            #expect(observed.events.elements.isEmpty)
            close(far)
        }

        @Test("A write after shutdown fails .shutDown, never inside the call")
        func writeAfterShutdown() async throws {
            let (local, far) = try RawSocket.pair()
            let observed = try ObservedStream(adopting: local)
            observed.stream.shutdown()
            let result = await observed.write([Data(count: 10)])
            #expect(result.error == .shutDown)
            #expect(!result.insideCall)
            await observed.waitForRelease()
            close(far)
        }

        @Test(
            "A socket error with nothing to read ends the read side with that error",
            .timeLimit(.minutes(1)))
        func pendingErrorEndsReadSide() async throws {
            let observed = try ObservedStream(adopting: try RawSocket.refusedDatagram())
            var events = observed.events.waiter()
            // At the time limit, shutdown() ends the wait with `.shutDown`, so the test fails rather than hangs.
            let end = await withTaskCancellationHandler {
                await events.next { _ in true }
            } onCancel: {
                observed.stream.shutdown()
            }
            #expect(end == .ended(.failed(.system(ECONNREFUSED))))
            observed.stream.shutdown()
            await observed.waitForRelease()
        }
    }
}
#endif
