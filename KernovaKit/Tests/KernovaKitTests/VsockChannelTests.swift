import Testing
import Foundation
import Darwin
import SwiftProtobuf
import KernovaTestSupport
@testable import KernovaKit

@Suite("VsockChannel", .caseScoped)
struct VsockChannelTests {
    // MARK: - Helpers

    /// Creates a raw `socketpair(AF_UNIX, SOCK_STREAM)`.
    ///
    /// AF_UNIX behaves identically to AF_VSOCK at the SOCK_STREAM level for our purposes
    /// and is testable on the host.
    private func rawSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return (fds[0], fds[1])
    }

    /// Creates two `VsockChannel`s connected by a `socketpair(AF_UNIX, SOCK_STREAM)`.
    private func makePair() throws -> (a: VsockChannel, b: VsockChannel) {
        let (fdA, fdB) = try rawSocketPair()
        return (VsockChannel(fileDescriptor: fdA), VsockChannel(fileDescriptor: fdB))
    }

    /// Creates a `VsockChannel` (started) paired with the *raw* fd of its peer,
    /// so a test can withhold reads on the peer side directly instead of going
    /// through another `VsockChannel`.
    ///
    /// Used to reproduce #457: a peer that stops draining lets a
    /// `VsockChannel.writeFramed` call park inside `write(2)`. Both ends'
    /// socket buffers are shrunk to a tiny, deterministic size (rather than
    /// relying on the platform's default, which can vary) so a modest write
    /// reliably blocks instead of being buffered away.
    private func makeChannelWithRawPeer() throws -> (channel: VsockChannel, rawPeerFd: Int32) {
        let (fd, rawPeerFd) = try rawSocketPair()
        var enable: Int32 = 1
        _ = setsockopt(rawPeerFd, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))
        var tinyBuffer: Int32 = 4096
        for eachFd in [fd, rawPeerFd] {
            _ = setsockopt(eachFd, SOL_SOCKET, SO_SNDBUF, &tinyBuffer, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(eachFd, SOL_SOCKET, SO_RCVBUF, &tinyBuffer, socklen_t(MemoryLayout<Int32>.size))
        }
        let channel = VsockChannel(fileDescriptor: fd)
        channel.start()
        return (channel, rawPeerFd)
    }

    /// Suspends until `fd` has bytes to read — proof its peer's write has begun.
    private func waitUntilReadable(_ fd: Int32) async throws {
        let stopwatch = BackstopStopwatch()
        let readable = await offCooperativePool {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while true {
                let remaining = max(0, testWaitBackstop - stopwatch.elapsed)
                let rc = poll(&descriptor, 1, Int32(remaining * 1000))
                if rc < 0 && errno == EINTR { continue }
                return rc > 0 && descriptor.revents & Int16(POLLIN) != 0
            }
        }
        guard readable else {
            throw TestFailure.backstop(
                "fd \(fd) never became readable within \(testWaitBackstop) s",
                stopwatch: stopwatch, timeout: testWaitBackstop)
        }
    }

    private func makeHello(serviceVersion: UInt32 = 1) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = serviceVersion
            $0.capabilities = ["clipboard.text"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = "0.1.0"
            }
        }
        return frame
    }

    // MARK: - Tests

    @Test("Round-trips a Hello frame")
    func roundTripHello() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { a.close(); b.close() }

        let sent = makeHello(serviceVersion: 7)
        try a.send(sent)

        let received = try await nextFrame(from: b)
        #expect(received.protocolVersion == 1)
        if case .hello(let hello) = received.payload {
            #expect(hello.serviceVersion == 7)
            #expect(hello.capabilities == ["clipboard.text"])
            #expect(hello.agentInfo.os == "macOS")
        } else {
            Issue.record("Expected hello payload, got \(String(describing: received.payload))")
        }
    }

    @Test("Delivers multiple frames in order")
    func multipleFramesPreserveOrder() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { a.close(); b.close() }

        for version in UInt32(1)...5 {
            try a.send(makeHello(serviceVersion: version))
        }

        var received: [UInt32] = []
        for _ in 1...5 {
            if case .hello(let hello) = try await nextFrame(from: b).payload {
                received.append(hello.serviceVersion)
            }
        }
        #expect(received == [1, 2, 3, 4, 5])
    }

    @Test("Local close finishes the incoming stream")
    func localCloseFinishesStream() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { b.close() }

        let consumer = Task { try await nextFrameOrEnd(from: a) }

        a.close()

        let value = try await consumer.value
        #expect(value == nil)
    }

    @Test("Remote close (EOF) finishes the incoming stream")
    func remoteCloseFinishesStream() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { a.close() }

        let consumer = Task { try await nextFrameOrEnd(from: a) }

        b.close()

        let value = try await consumer.value
        #expect(value == nil)
    }

    /// Writes two frames as one `write(2)`, so the receiver's readability
    /// handler decodes and yields both in the same callback.
    ///
    /// Once the first frame has been delivered, the second is therefore
    /// provably sitting in `incoming`'s buffer — the state a test about what
    /// happens to a buffered frame has to be in, and one no channel API
    /// otherwise reports.
    private func sendAsOneChunk(_ frames: [Frame], on channel: VsockChannel) throws {
        var bytes = Data()
        for frame in frames {
            bytes.append(try VsockChannel.serializeFramed(frame))
        }
        try channel.writeFramed(bytes)
    }

    /// Whether any byte is still sitting unread in `fd`'s receive buffer.
    ///
    /// `MSG_PEEK` leaves whatever it finds in place, so the channel's own reader
    /// still gets it.
    private func hasUnreadBytes(on fd: Int32) -> Bool {
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0
    }

    @Test("A frame buffered when the owner closes is never delivered")
    func ownerCloseDropsABufferedFrame() async throws {
        let (fdA, fdB) = try rawSocketPair()
        let a = VsockChannel(fileDescriptor: fdA)
        let b = VsockChannel(fileDescriptor: fdB)
        a.start()
        b.start()
        defer { a.close(); b.close() }

        try sendAsOneChunk([makeHello(serviceVersion: 1), makeHello(serviceVersion: 2)], on: a)

        let first = try await nextFrame(from: b)
        guard case .hello(let hello) = first.payload, hello.serviceVersion == 1 else {
            Issue.record("Expected the first hello, got \(String(describing: first.payload))")
            return
        }
        // The test's premise, and not otherwise observable: the first frame's
        // delivery means the readability handler decoded the whole chunk, so
        // the second is in `incoming`'s buffer. Left on the socket instead, the
        // close would drop it by nilling the handler and prove nothing.
        #expect(!hasUnreadBytes(on: fdB))

        b.close()

        let afterClose = try await nextFrameOrEnd(from: b)
        #expect(afterClose == nil)
    }

    @Test("A frame buffered when the peer hangs up is still delivered")
    func peerEOFStillDeliversABufferedFrame() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { a.close(); b.close() }

        try sendAsOneChunk([makeHello(serviceVersion: 1), makeHello(serviceVersion: 2)], on: a)

        _ = try await nextFrame(from: b)

        // The peer's own close is not this channel's: what it had already sent
        // is still owed to the consumer.
        a.close()

        let second = try await nextFrame(from: b)
        guard case .hello(let hello) = second.payload else {
            Issue.record("Expected the second hello, got \(String(describing: second.payload))")
            return
        }
        #expect(hello.serviceVersion == 2)
    }

    @Test("A decode failure surfaces to the consumer as a thrown error")
    func decodeFailureThrowsToTheConsumer() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { a.close(); b.close() }

        // A well-framed payload that is not a `Frame`: the length prefix is
        // honoured, so the failure is the protobuf decode, which finishes the
        // stream with its error rather than with EOF.
        try a.writeFramed(try StreamFrame.encode(Data([0xFF, 0xFF, 0xFF, 0xFF])))

        // The specific decode error, not `any Error`: `nextFrame`'s own
        // `TestFailure` would satisfy that and pass this test on a stall.
        await #expect(throws: BinaryDecodingError.self) {
            _ = try await nextFrame(from: b)
        }
    }

    @Test("send after close throws .closed")
    func sendAfterCloseThrows() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { b.close() }

        a.close()

        #expect(throws: VsockChannelError.closed) {
            try a.send(makeHello())
        }
    }

    @Test("sendErrorFrame round-trips an Error payload with inReplyTo set")
    func sendErrorFrameRoundTrips() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { a.close(); b.close() }

        try a.sendErrorFrame(code: "test.code", message: "test message", inReplyTo: "test.reply")

        let received = try await nextFrame(from: b)
        #expect(received.protocolVersion == 1)
        guard case .error(let err) = received.payload else {
            Issue.record("Expected error payload, got \(String(describing: received.payload))")
            return
        }
        #expect(err.code == "test.code")
        #expect(err.message == "test message")
        #expect(err.hasInReplyTo)
        #expect(err.inReplyTo == "test.reply")
    }

    @Test("sendErrorFrame omits inReplyTo when nil")
    func sendErrorFrameOmitsInReplyTo() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { a.close(); b.close() }

        try a.sendErrorFrame(code: "test.code", message: "test", inReplyTo: nil)

        let received = try await nextFrame(from: b)
        #expect(received.protocolVersion == 1)
        guard case .error(let err) = received.payload else {
            Issue.record("Expected error payload")
            return
        }
        #expect(err.code == "test.code")
        #expect(err.message == "test")
        #expect(err.hasInReplyTo == false)
    }

    @Test("Inbound decode proceeds while a write is blocked on a stalled peer (#457)")
    func inboundDecodeProceedsWhileWriteIsBlocked() async throws {
        let (channel, rawPeerFd) = try makeChannelWithRawPeer()
        defer {
            channel.close()
            Darwin.close(rawPeerFd)
        }

        // Comfortably exceeds the tiny 4 KiB SO_SNDBUF/SO_RCVBUF the helper set
        // on both ends, so — since `rawPeerFd` is never read in this test —
        // `writeFramed` parks inside `write(2)` for the rest of the test. On
        // the pre-#457 single-lock implementation this holds the lock
        // `handleChunk` also needs, so the Hello sent below would never decode
        // and this test would time out.
        let bigBlob = Data(count: 1024 * 1024)
        let writeTask = Task<Void, Never> {
            _ = try? channel.writeFramed(bigBlob)
        }
        defer { writeTask.cancel() }

        try await waitUntilReadable(rawPeerFd)

        let helloBytes = try VsockChannel.serializeFramed(makeHello(serviceVersion: 42))
        try helloBytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var written = 0
            while written < buffer.count {
                let rc = Darwin.write(rawPeerFd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                guard rc > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                written += rc
            }
        }

        let received = try await nextFrame(from: channel)
        if case .hello(let hello) = received.payload {
            #expect(hello.serviceVersion == 42)
        } else {
            Issue.record("Expected hello payload, got \(String(describing: received.payload))")
        }
    }

    @Test("Teardown unblocks a write parked on a stalled peer (#457)")
    func teardownUnblocksParkedWrite() async throws {
        let (channel, rawPeerFd) = try makeChannelWithRawPeer()
        defer {
            channel.close()
            Darwin.close(rawPeerFd)
        }

        let bigBlob = Data(count: 1024 * 1024)
        let writeTask = Task<VsockChannelError?, Never> {
            do {
                try channel.writeFramed(bigBlob)
                return nil
            } catch let error as VsockChannelError {
                return error
            } catch {
                return nil
            }
        }

        // The 1 MiB write cannot fit the 4 KiB buffers the peer never drains, so
        // once its first bytes land it stays parked until teardown.
        try await waitUntilReadable(rawPeerFd)

        channel.close()

        // The parked write unblocks and surfaces as a write failure once
        // `close()` shuts the descriptor down out from under it.
        let outcome = await writeTask.value
        #expect(outcome == .write(POSIXError(.EPIPE)))
    }

    @Test("send throws .write when the underlying FileHandle write fails")
    func sendThrowsWriteOnUnderlyingFailure() async throws {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        // SO_NOSIGPIPE so writing to a peer-closed socket surfaces as an
        // error rather than killing the test process with SIGPIPE.
        var enable: Int32 = 1
        _ = setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size))

        // Close the peer end so the next write to fds[0] hits EPIPE.
        Darwin.close(fds[1])

        // Left unstarted: a started channel's readability handler observes the
        // EOF and closes the channel before the write, which then throws
        // `.closed` instead of `.write`.
        let a = VsockChannel(fileDescriptor: fds[0])
        defer { a.close() }

        #expect {
            try a.send(makeHello())
        } throws: { error in
            guard let channelError = error as? VsockChannelError else { return false }
            if case .write = channelError { return true }
            return false
        }
    }
}
