import Testing
import Foundation
import Darwin
@testable import KernovaProtocol

@Suite("VsockChannel")
struct VsockChannelTests {

    // MARK: - Helpers

    /// Creates two `VsockChannel`s connected by a `socketpair(AF_UNIX, SOCK_STREAM)`.
    /// AF_UNIX behaves identically to AF_VSOCK at the SOCK_STREAM level for our purposes
    /// and is testable on the host.
    private func makePair() throws -> (a: VsockChannel, b: VsockChannel) {
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

    /// Awaits the next frame from a channel's `incoming` stream, failing if it doesn't
    /// arrive within `timeout`.
    private func waitForNextFrame(
        on channel: VsockChannel,
        timeout: Duration = .seconds(2)
    ) async throws -> Frame? {
        let receiver = Task<Frame?, Error> {
            var iterator = channel.incoming.makeAsyncIterator()
            return try await iterator.next()
        }
        let timeoutTask = Task<Void, Error> {
            try await Task.sleep(for: timeout)
            receiver.cancel()
        }
        defer { timeoutTask.cancel() }

        do {
            return try await receiver.value
        } catch is CancellationError {
            throw TestTimeout()
        }
    }

    private struct TestTimeout: Error {}

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

        let received = try await waitForNextFrame(on: b)
        #expect(received?.protocolVersion == 1)
        if case .hello(let hello) = received?.payload {
            #expect(hello.serviceVersion == 7)
            #expect(hello.capabilities == ["clipboard.text"])
            #expect(hello.agentInfo.os == "macOS")
        } else {
            Issue.record("Expected hello payload, got \(String(describing: received?.payload))")
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
        var iterator = b.incoming.makeAsyncIterator()
        let collector = Task<[UInt32], Error> {
            var collected: [UInt32] = []
            while collected.count < 5, let frame = try await iterator.next() {
                if case .hello(let hello) = frame.payload {
                    collected.append(hello.serviceVersion)
                }
            }
            return collected
        }
        let timeoutTask = Task<Void, Error> {
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
        }
        defer { timeoutTask.cancel() }

        do {
            received = try await collector.value
        } catch is CancellationError {
            Issue.record("Timed out collecting frames")
        }
        #expect(received == [1, 2, 3, 4, 5])
    }

    @Test("Local close finishes the incoming stream")
    func localCloseFinishesStream() async throws {
        let (a, b) = try makePair()
        a.start()
        b.start()
        defer { b.close() }

        // Spawn the consumer first so it's blocked in next().
        let consumer = Task<Frame?, Error> {
            var iterator = a.incoming.makeAsyncIterator()
            return try await iterator.next()
        }
        // Tiny yield to let the consumer enter next().
        try await Task.sleep(for: .milliseconds(10))

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

        let consumer = Task<Frame?, Error> {
            var iterator = a.incoming.makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(10))

        b.close()

        let value = try await consumer.value
        #expect(value == nil)
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
}
