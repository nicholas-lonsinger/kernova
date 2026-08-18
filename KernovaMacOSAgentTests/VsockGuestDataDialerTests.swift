import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

/// The dialler every clipboard and drop transfer opens its data connection
/// through: its own gate label, and the socket options a transfer's reads and
/// writes are bounded by.
@Suite("VsockGuestDataDialer")
struct VsockGuestDataDialerTests {
    /// The seconds a `timeval` socket option holds.
    private func timeout(_ option: Int32, on fd: Int32) -> Int? {
        var value = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        guard getsockopt(fd, SOL_SOCKET, option, &value, &length) == 0 else { return nil }
        return value.tv_sec
    }

    @Test("a dialled connection carries the stall bound in both directions")
    func appliesTheSocketTimeouts() throws {
        let (near, far) = try makeRawSocketPair()
        defer { close(far) }

        let fd = try VsockGuestDataDialer.connect(port: 49_156) { _, _ in .success(near) }
        defer { close(fd) }

        #expect(fd == near)
        #expect(timeout(SO_RCVTIMEO, on: fd) == Int(ClipboardStreamTuning.dataSocketTimeout))
        #expect(timeout(SO_SNDTIMEO, on: fd) == Int(ClipboardStreamTuning.dataSocketTimeout))
    }

    /// A parked data connect must not spend the reconnect loop's own budget of
    /// blocking-connect slots, so it claims the gate under a label of its own.
    @Test("a dial claims the gate under the data label, not a channel's")
    func dialsUnderItsOwnGateLabel() throws {
        let (near, far) = try makeRawSocketPair()
        defer {
            close(near)
            close(far)
        }

        let seen = Box<String?>(nil)
        _ = try VsockGuestDataDialer.connect(port: 49_157) { _, label in
            seen.value = label
            return .success(near)
        }

        #expect(seen.value == VsockGuestDataDialer.gateLabel)
        #expect(VsockGuestDataDialer.gateLabel != "clipboard")
        #expect(VsockGuestDataDialer.gateLabel != "drop")
    }

    @Test("the port asked for is the port dialled")
    func dialsThePortItIsGiven() throws {
        let (near, far) = try makeRawSocketPair()
        defer {
            close(near)
            close(far)
        }

        let seen = Box<UInt32?>(nil)
        _ = try VsockGuestDataDialer.connect(port: KernovaVsockPort.dropData) { port, _ in
            seen.value = port
            return .success(near)
        }

        #expect(seen.value == KernovaVsockPort.dropData)
    }

    @Test("a connect that never completes is thrown, not returned as a descriptor")
    func rethrowsAProviderFailure() {
        #expect(throws: VsockProviderError.transient("no host")) {
            _ = try VsockGuestDataDialer.connect(port: 49_156) { _, _ in
                .failure(.transient("no host"))
            }
        }
    }
}
