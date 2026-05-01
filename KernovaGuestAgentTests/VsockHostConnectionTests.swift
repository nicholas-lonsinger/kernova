import Testing
import Foundation
import Darwin
import KernovaProtocol

@Suite("VsockHostConnection log buffer")
struct VsockHostConnectionTests {

    // MARK: - Helpers

    private func makePair() throws -> (sender: VsockChannel, receiver: VsockChannel) {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        guard rc == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return (VsockChannel(fileDescriptor: fds[0]),
                VsockChannel(fileDescriptor: fds[1]))
    }

    /// Returns a thread-safe snapshot of the pending log buffer.
    private func pendingLogCount(_ conn: VsockHostConnection) -> Int {
        conn.lock.withLock { conn.pendingLogs.count }
    }

    /// Returns a thread-safe snapshot of the pending log messages.
    private func pendingMessages(_ conn: VsockHostConnection) -> [String] {
        conn.lock.withLock {
            conn.pendingLogs.compactMap { frame -> String? in
                guard case .logRecord(let record) = frame.payload else { return nil }
                return record.message
            }
        }
    }

    /// Builds a minimal LogRecord frame for testing buffer contents.
    private func makeLogFrame(message: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.logRecord = Kernova_V1_LogRecord.with {
            $0.timestampMs = 0
            $0.level = .info
            $0.subsystem = "test"
            $0.category = "test"
            $0.message = message
        }
        return frame
    }

    /// Drains the next frame from a channel within a generous deadline.
    private func nextFrame(
        from channel: VsockChannel,
        timeout: Duration = .seconds(2)
    ) async throws -> Frame {
        let receiver = Task<Frame?, Error> {
            var iterator = channel.incoming.makeAsyncIterator()
            return try await iterator.next()
        }
        let timeoutTask = Task<Void, Error> {
            try await Task.sleep(for: timeout)
            receiver.cancel()
        }
        defer { timeoutTask.cancel() }
        guard let frame = try await receiver.value else {
            throw TestFailure("Channel finished without producing a frame")
        }
        return frame
    }

    private struct TestFailure: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    // MARK: - Buffer: basic enqueue

    @Test("forwardLog buffers frames when no live channel is present")
    func buffersWhenNoChannel() {
        let conn = VsockHostConnection()

        for i in 0..<5 {
            conn.forwardLog(level: .info, subsystem: "test", category: "test", message: "msg\(i)")
        }

        #expect(pendingLogCount(conn) == 5)
    }

    @Test("buffered frames are in FIFO order")
    func bufferedFramesInFIFOOrder() {
        let conn = VsockHostConnection()

        for i in 0..<3 {
            conn.forwardLog(level: .info, subsystem: "test", category: "test", message: "msg\(i)")
        }

        let messages = pendingMessages(conn)
        #expect(messages == ["msg0", "msg1", "msg2"])
    }

    // MARK: - Buffer cap

    @Test("buffer drops oldest frames when over cap")
    func bufferDropsOldestOverCap() {
        let conn = VsockHostConnection()
        let total = 300
        let cap = VsockHostConnection.logBufferLimit

        for i in 0..<total {
            conn.bufferFrame(makeLogFrame(message: "frame\(i)"))
        }

        let count = pendingLogCount(conn)
        #expect(count == cap)

        // Oldest surviving frame should be at index (total - cap) = 44
        let messages = pendingMessages(conn)
        #expect(messages.first == "frame\(total - cap)")
    }

    @Test("buffer cap is exactly logBufferLimit")
    func bufferCapIsExact() {
        let conn = VsockHostConnection()
        let cap = VsockHostConnection.logBufferLimit

        for i in 0..<(cap + 10) {
            conn.bufferFrame(makeLogFrame(message: "f\(i)"))
        }

        #expect(pendingLogCount(conn) == cap)
    }

    // MARK: - flushPendingLogs: healthy channel

    @Test("flushPendingLogs drains all frames in order on a healthy channel")
    func flushDrainsInOrderOnHealthyChannel() async throws {
        let conn = VsockHostConnection()
        let frameCount = 10

        for i in 0..<frameCount {
            conn.bufferFrame(makeLogFrame(message: "flush\(i)"))
        }

        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close(); receiver.close() }

        conn.flushPendingLogs(on: sender)

        // Collect frameCount frames from receiver
        var received: [Frame] = []
        for _ in 0..<frameCount {
            let frame = try await nextFrame(from: receiver)
            received.append(frame)
        }

        #expect(pendingLogCount(conn) == 0)
        #expect(received.count == frameCount)

        // Verify order
        let messages = received.compactMap { frame -> String? in
            guard case .logRecord(let record) = frame.payload else { return nil }
            return record.message
        }
        let expected = (0..<frameCount).map { "flush\($0)" }
        #expect(messages == expected)
    }

    @Test("flushPendingLogs leaves buffer empty after full drain")
    func flushLeavesBufferEmptyAfterFullDrain() async throws {
        let conn = VsockHostConnection()

        for i in 0..<5 {
            conn.bufferFrame(makeLogFrame(message: "m\(i)"))
        }

        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close(); receiver.close() }

        conn.flushPendingLogs(on: sender)

        // Drain receiver so it doesn't block
        for _ in 0..<5 {
            _ = try await nextFrame(from: receiver)
        }

        #expect(pendingLogCount(conn) == 0)
    }

    // MARK: - flushPendingLogs: partial failure re-enqueue

    @Test("flushPendingLogs re-enqueues unflushed remainder after send failure")
    func flushReenqueuesOnSendFailure() throws {
        let conn = VsockHostConnection()
        let frameCount = 10

        for i in 0..<frameCount {
            conn.bufferFrame(makeLogFrame(message: "r\(i)"))
        }

        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()

        // Use channel.close() (not OS close) so VsockChannel's send() throws
        // VsockChannelError.closed on the very first attempt rather than
        // delivering SIGPIPE. This is deterministic and signal-free.
        sender.close()
        receiver.close()

        conn.flushPendingLogs(on: sender)

        // All frames should be re-enqueued since every send() throws .closed
        let remaining = pendingLogCount(conn)
        #expect(remaining == frameCount)
    }

    // MARK: - Re-enqueue respects cap

    @Test("re-enqueued frames plus new arrivals never exceed logBufferLimit")
    func reenqueueRespectsBufferCap() throws {
        let conn = VsockHostConnection()
        let cap = VsockHostConnection.logBufferLimit

        // Fill buffer to cap
        for i in 0..<cap {
            conn.bufferFrame(makeLogFrame(message: "pre\(i)"))
        }

        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()

        // Use channel.close() so sends throw .closed without SIGPIPE
        sender.close()
        receiver.close()

        conn.flushPendingLogs(on: sender)

        // Push more frames after the failed flush
        for i in 0..<10 {
            conn.bufferFrame(makeLogFrame(message: "post\(i)"))
        }

        let finalCount = pendingLogCount(conn)
        #expect(finalCount <= cap)
    }
}
