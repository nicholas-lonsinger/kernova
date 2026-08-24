import Darwin
import Foundation
import KernovaTestSupport
import Synchronization
import Testing

@testable import Kernova

/// One data port's routing between the listener's accept thread and the service
/// generation that currently owns its connections.
@Suite("VsockDataConnectionSink", .admissionGated)
struct VsockDataConnectionSinkTests {
    private final class RecordingAcceptor: VsockDataConnectionAccepting {
        private let fds = Mutex<[Int32]>([])
        var accepted: [Int32] { fds.withLock { $0 } }

        nonisolated func acceptDataConnection(fd: Int32) {
            fds.withLock { $0.append(fd) }
        }
    }

    /// Whether the peer end reads EOF — the sink (or its service) closed the
    /// forwarded descriptor.
    private func peerSeesEOF(_ peer: Int32) -> Bool {
        guard fcntl(peer, F_SETFL, O_NONBLOCK) >= 0 else { return false }
        var byte: UInt8 = 0
        return recv(peer, &byte, 1, 0) == 0
    }

    @Test("With no service set, an accepted descriptor is ended")
    func unsetEndsTheDescriptor() throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }  // `a` is owned — and must be closed — by the sink.

        let sink = VsockDataConnectionSink()
        sink.accept(fd: a)

        #expect(peerSeesEOF(b))
    }

    @Test("A set service takes over the descriptor as it is")
    func setServiceTakesTheDescriptor() throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }

        let sink = VsockDataConnectionSink()
        let service = RecordingAcceptor()
        sink.set(service)
        sink.accept(fd: a)

        #expect(service.accepted == [a])
        // Forwarded open, not closed: the service owns it now.
        #expect(fcntl(b, F_SETFL, O_NONBLOCK) >= 0)
        var byte: UInt8 = 0
        #expect(recv(b, &byte, 1, 0) == -1)
        #expect(errno == EAGAIN || errno == EWOULDBLOCK)
    }

    @Test("Replacing the service routes later descriptors to the replacement")
    func replacementTakesLaterDescriptors() throws {
        let (a, b) = try makeRawSocketPair()
        defer {
            close(a)
            close(b)
        }

        let sink = VsockDataConnectionSink()
        let first = RecordingAcceptor()
        let second = RecordingAcceptor()
        sink.set(first)
        sink.set(second)
        sink.accept(fd: a)

        #expect(first.accepted.isEmpty)
        #expect(second.accepted == [a])
    }

    @Test("Clearing the service ends later descriptors")
    func clearedSinkEndsTheDescriptor() throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }

        let sink = VsockDataConnectionSink()
        sink.set(RecordingAcceptor())
        sink.set(nil)
        sink.accept(fd: a)

        #expect(peerSeesEOF(b))
    }
}
