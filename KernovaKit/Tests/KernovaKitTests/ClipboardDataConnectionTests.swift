import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The socket options a data connection is opened under: the stall bound both
/// ends read and write against, and the throughput lever only the end that
/// accepted the descriptor *and* streams on it takes.
@Suite("ClipboardDataConnection socket options")
struct ClipboardDataConnectionTests {
    /// A connected descriptor and the peer end that keeps it connected.
    ///
    /// The peer is never read or written: it is held open only so `near` stays
    /// a live connection, since the options under test are read back off it.
    private struct ConnectedSocket {
        let near: Int32
        private let peer: Int32

        init() throws {
            (near, peer) = try makeRawSocketPair()
        }

        func close() {
            Darwin.close(near)
            Darwin.close(peer)
        }
    }

    /// The seconds a `timeval` socket option holds.
    private func timeout(_ option: Int32, on fd: Int32) -> Int? {
        var value = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        guard getsockopt(fd, SOL_SOCKET, option, &value, &length) == 0 else { return nil }
        return value.tv_sec
    }

    private func sendBuffer(on fd: Int32) -> Int32? {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &value, &length) == 0 else { return nil }
        return value
    }

    @Test("the stall bound is carried in both directions")
    func stallBoundAppliedBothWays() throws {
        let socket = try ConnectedSocket()
        defer { socket.close() }

        ClipboardDataConnection.applySocketOptions(fd: socket.near)

        let bound = Int(ClipboardStreamTuning.dataSocketTimeout)
        #expect(timeout(SO_RCVTIMEO, on: socket.near) == bound)
        #expect(timeout(SO_SNDTIMEO, on: socket.near) == bound)
    }

    @Test("an injected timeout is what the socket carries")
    func injectedTimeoutIsApplied() throws {
        let socket = try ConnectedSocket()
        defer { socket.close() }

        ClipboardDataConnection.applySocketOptions(fd: socket.near, timeout: 5)

        #expect(timeout(SO_RCVTIMEO, on: socket.near) == 5)
        #expect(timeout(SO_SNDTIMEO, on: socket.near) == 5)
    }

    /// Applying the connection's options twice is what the accept path and the
    /// transfer that adopts the descriptor between them do, and the second is
    /// the one whose timeout stands.
    @Test("re-applying the options replaces the bound rather than compounding it")
    func optionsAreIdempotent() throws {
        let socket = try ConnectedSocket()
        defer { socket.close() }

        ClipboardDataConnection.applySocketOptions(fd: socket.near)
        ClipboardDataConnection.applySocketOptions(fd: socket.near, timeout: 7)

        #expect(timeout(SO_RCVTIMEO, on: socket.near) == 7)
        #expect(timeout(SO_SNDTIMEO, on: socket.near) == 7)
    }

    /// The connection's own options leave the send buffer where the kernel put
    /// it: a descriptor this side only ever reads from spends nothing on one,
    /// and a dialler has already sized its own.
    @Test("the connection's options leave the send buffer alone")
    func optionsLeaveTheSendBufferAlone() throws {
        let socket = try ConnectedSocket()
        defer { socket.close() }
        let before = try #require(sendBuffer(on: socket.near))

        ClipboardDataConnection.applySocketOptions(fd: socket.near)

        #expect(sendBuffer(on: socket.near) == before)
    }

    /// The end that accepted the descriptor owns the throughput lever: a freshly
    /// accepted socket is born at 8 KiB, which is what caps host→guest streaming
    /// (docs/research/2026-07-13-vsock-transport-throughput.md). Asserted at the
    /// measured 256 KiB knee rather than the exact request, which the kernel may
    /// clamp.
    @Test("raising the send buffer clears the throughput knee")
    func raisingTheSendBufferClearsTheKnee() throws {
        let socket = try ConnectedSocket()
        defer { socket.close() }

        ClipboardDataConnection.raiseSendBuffer(fd: socket.near)

        #expect((sendBuffer(on: socket.near) ?? 0) >= 256 * 1024)
    }
}
