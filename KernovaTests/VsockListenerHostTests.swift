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
    /// This is the host→guest throughput lever (#377). XNU births the socket at an
    /// 8 KiB `net.local.stream.sendspace` default; the option should land at least
    /// at the measured 256 KiB knee, and above whatever the default was.
    @Test("configureAcceptedSocket enlarges the send buffer")
    func configureAcceptedSocketEnlargesSendBuffer() throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }

        let host = VsockListenerHost(port: 49_152) { _ in }

        var defaultSize: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(a, SOL_SOCKET, SO_SNDBUF, &defaultSize, &len) == 0)

        host.configureAcceptedSocket(a)

        var applied: Int32 = 0
        len = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(a, SOL_SOCKET, SO_SNDBUF, &applied, &len) == 0)
        #expect(applied >= 256 * 1024)
        #expect(applied > defaultSize)
    }
}
