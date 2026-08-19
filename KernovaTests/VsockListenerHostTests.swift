import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Synchronization
import Testing
import Virtualization

@testable import Kernova

@MainActor
@Suite("VsockListenerHost", .admissionGated)
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

        let host = VsockListenerHost(port: 49_152, onConnect: { _ in })

        host.configureAcceptedSocket(a)

        var applied: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(a, SOL_SOCKET, SO_SNDBUF, &applied, &len) == 0)
        #expect(applied >= 256 * 1024)
    }

    // MARK: - Admission (#145)

    @Test(
        "Either refusal verdict refuses the connection and closes the fd",
        arguments: [
            VsockAdmission.notReady(reason: "test: handshake pending"),
            .denied(reason: "test: peer not entitled"),
        ])
    func admissionRefusalClosesFd(verdict: VsockAdmission) async throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }  // `a` is owned — and must be closed — by the listener.

        let connected = Mutex(false)
        let host = VsockListenerHost(
            port: 49_153, shouldAdmit: { verdict },
            onConnect: { _ in connected.withLock { $0 = true } })

        #expect(host.acceptDuplicatedFd(a, dupErrno: 0) == false)
        // A refused connection queues no hand-off; one bridged turn proves it.
        await drainMainQueue()
        #expect(connected.withLock { $0 } == false)
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

    @Test("A passing admission check accepts and hands the channel to main")
    func admissionPassAcceptsConnection() async throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }

        let received = Mutex<VsockChannel?>(nil)
        let host = VsockListenerHost(port: 49_153, shouldAdmit: { .admit }) { channel in
            #expect(Thread.isMainThread)
            received.withLock { $0 = channel }
        }

        #expect(host.acceptDuplicatedFd(a, dupErrno: 0) == true)
        // The hand-off rides the FIFO main-queue bridge, so one turn delivers it.
        await drainMainQueue()
        let channel = try #require(received.withLock { $0 })
        channel.close()
    }

    @Test("No admission check admits every connection (control listener)")
    func nilAdmissionAdmits() async throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }

        let received = Mutex<VsockChannel?>(nil)
        let host = VsockListenerHost(port: 49_154) { channel in
            received.withLock { $0 = channel }
        }

        #expect(host.acceptDuplicatedFd(a, dupErrno: 0) == true)
        await drainMainQueue()
        let channel = try #require(received.withLock { $0 })
        channel.close()
    }

    // MARK: - Data ports

    /// A data port hands the descriptor over as it is, with no channel built on
    /// it: one transfer's connection carries its own header, payload and
    /// trailer rather than a stream of frames.
    @Test("A data listener hands over the raw descriptor rather than a channel")
    func dataListenerHandsOverTheDescriptor() throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }

        let handedOver = Mutex<Int32?>(nil)
        let host = VsockListenerHost(
            port: KernovaVsockPort.clipboardData, shouldAdmit: { .admit },
            onAcceptFd: { fd in handedOver.withLock { $0 = fd } })

        #expect(host.acceptDuplicatedFd(a, dupErrno: 0) == true)
        #expect(handedOver.withLock { $0 } == a)
        // Nothing was written to the descriptor: a channel would have started
        // its own read loop and the endpoint's first header read would race it.
        #expect(fcntl(b, F_SETFL, O_NONBLOCK) >= 0)
        var byte: UInt8 = 0
        #expect(recv(b, &byte, 1, 0) == -1)
        #expect(errno == EAGAIN || errno == EWOULDBLOCK)
    }

    /// The invariant the accept path exists to keep: a data connection is
    /// handed over on the thread VZ accepted it on, before the delegate
    /// callback returns, with no main-queue hop in between.
    @Test("A data port's hand-off runs synchronously on the accepting thread")
    func dataHandoffRunsSynchronouslyOffMain() async throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }

        let handedOver = Mutex<Int32?>(nil)
        let host = VsockListenerHost(
            port: KernovaVsockPort.clipboardData, shouldAdmit: { .admit },
            onAcceptFd: { fd in
                #expect(!Thread.isMainThread)
                handedOver.withLock { $0 = fd }
            })

        // As VZ will deliver it once the VM leaves the main queue: accepted off
        // main, and — by `&&`'s ordering — handed over before the delegate
        // callback returned, on that same thread.
        let handedOverBeforeReturn = await offCooperativePool {
            host.acceptDuplicatedFd(a, dupErrno: 0) && handedOver.withLock { $0 } == a
        }
        #expect(handedOverBeforeReturn)
    }

    @Test(
        "A data listener's refusal closes the descriptor and hands over nothing",
        arguments: [
            VsockAdmission.notReady(reason: "test: handshake pending"),
            .denied(reason: "test: peer not entitled"),
        ])
    func dataListenerRefusalClosesFd(verdict: VsockAdmission) throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }  // `a` is owned — and must be closed — by the listener.

        let handedOver = Mutex<Int32?>(nil)
        let host = VsockListenerHost(
            port: KernovaVsockPort.dropData, shouldAdmit: { verdict },
            onAcceptFd: { fd in handedOver.withLock { $0 = fd } })

        #expect(host.acceptDuplicatedFd(a, dupErrno: 0) == false)
        #expect(handedOver.withLock { $0 } == nil)
        #expect(fcntl(b, F_SETFL, O_NONBLOCK) >= 0)
        var byte: UInt8 = 0
        #expect(recv(b, &byte, 1, 0) == 0)
    }
}
