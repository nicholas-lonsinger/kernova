import Darwin
import Foundation
import KernovaKit
import Testing
import Virtualization

@testable import Kernova

@MainActor
@Suite("VsockListenerHost")
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

    // MARK: - Admission (#145)

    @Test("A failing admission check refuses the connection and closes the fd")
    func admissionRefusalClosesFd() throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }  // `a` is owned — and must be closed — by the listener.

        var connected = false
        let host = VsockListenerHost(port: 49_153, shouldAdmit: { false }) { _ in
            connected = true
        }

        #expect(host.acceptDuplicatedFd(a, dupErrno: 0) == false)
        #expect(connected == false)
        // The refused duplicate must not leak. Observe the closure from the
        // peer end: the refusal path close(2)s `a` synchronously before
        // returning, so a non-blocking read on `b` sees EOF (0) — a
        // leaked-open `a` would yield -1/EAGAIN instead. (Asserting on `a`
        // itself via fcntl would race fd-number reuse by concurrently-running
        // suites in this process.)
        #expect(fcntl(b, F_SETFL, O_NONBLOCK) >= 0)
        var byte: UInt8 = 0
        #expect(recv(b, &byte, 1, 0) == 0)
    }

    @Test("A passing admission check accepts and hands over the channel")
    func admissionPassAcceptsConnection() throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }

        var received: VsockChannel?
        let host = VsockListenerHost(port: 49_153, shouldAdmit: { true }) { channel in
            received = channel
        }

        #expect(host.acceptDuplicatedFd(a, dupErrno: 0) == true)
        let channel = try #require(received)
        channel.close()
    }

    @Test("No admission check admits every connection (control listener)")
    func nilAdmissionAdmits() throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }

        var received: VsockChannel?
        let host = VsockListenerHost(port: 49_154) { channel in
            received = channel
        }

        #expect(host.acceptDuplicatedFd(a, dupErrno: 0) == true)
        let channel = try #require(received)
        channel.close()
    }
}
