import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The socket options every data connection is opened under: the throughput
/// lever on the accepting side, and the stall bound both sides read and write
/// against.
@Suite("ClipboardDataConnection socket options")
struct ClipboardDataConnectionTests {
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

    @Test("both roles carry the stall bound in both directions")
    func bothRolesCarryTheStallBound() throws {
        for role in [ClipboardDataConnection.Role.host, .guest] {
            let (a, b) = try makeRawSocketPair()
            defer {
                close(a)
                close(b)
            }

            ClipboardDataConnection.applySocketOptions(fd: a, role: role)

            #expect(timeout(SO_RCVTIMEO, on: a) == Int(ClipboardStreamTuning.dataSocketTimeout))
            #expect(timeout(SO_SNDTIMEO, on: a) == Int(ClipboardStreamTuning.dataSocketTimeout))
        }
    }

    /// The accepting side owns the throughput lever: a freshly accepted socket
    /// is born at 8 KiB, which is what caps host→guest streaming
    /// (docs/research/2026-07-13-vsock-transport-throughput.md). Asserted at the
    /// measured 256 KiB knee rather than the exact request, which the kernel may
    /// clamp.
    @Test("the accepting side raises its send buffer past the throughput knee")
    func hostRaisesTheSendBuffer() throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }

        ClipboardDataConnection.applySocketOptions(fd: a, role: .host)

        #expect((sendBuffer(on: a) ?? 0) >= 256 * 1024)
    }

    /// The dialling side's socket lives in the guest, where the writer is
    /// Apple's VM helper rather than this process, so raising the buffer here
    /// would cost memory and unlock nothing.
    @Test("the dialling side leaves its send buffer alone")
    func guestLeavesTheSendBufferAlone() throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }
        let before = try #require(sendBuffer(on: a))

        ClipboardDataConnection.applySocketOptions(fd: a, role: .guest)

        #expect(sendBuffer(on: a) == before)
    }

    @Test("an injected timeout is what the socket carries")
    func injectedTimeoutIsApplied() throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }

        ClipboardDataConnection.applySocketOptions(fd: a, role: .guest, timeout: 5)

        #expect(timeout(SO_RCVTIMEO, on: a) == 5)
        #expect(timeout(SO_SNDTIMEO, on: a) == 5)
    }
}
