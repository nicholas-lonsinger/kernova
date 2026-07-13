import Darwin
import Foundation
import Testing
import Virtualization

@testable import Kernova

@MainActor
@Suite("VsockListenerHost socket configuration")
struct VsockListenerHostTests {
    /// `configureAcceptedSocket` must raise `SO_SNDBUF` on the accepted fd.
    ///
    /// This is the host→guest throughput lever (#377). Assert the buffer lands at
    /// least at the measured 256 KiB knee — the threshold below which the lever
    /// stops unlocking throughput. (Asserting against the pre-set default instead
    /// would encode a host `net.local.stream.sendspace` assumption rather than the
    /// behavior under test.)
    @Test("configureAcceptedSocket enlarges the send buffer")
    func configureAcceptedSocketEnlargesSendBuffer() throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }

        let host = VsockListenerHost(port: 49_152) { _ in }

        host.configureAcceptedSocket(a)

        var applied: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(a, SOL_SOCKET, SO_SNDBUF, &applied, &len) == 0)
        #expect(applied >= 256 * 1024)
    }
}
