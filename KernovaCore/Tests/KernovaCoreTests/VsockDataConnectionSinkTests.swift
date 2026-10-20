import Foundation
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore

/// One data port's routing between the listener's accept thread and the service
/// generation that currently owns its connections.
@Suite("VsockDataConnectionSink", .caseScoped)
struct VsockDataConnectionSinkTests {
    private final class RecordingAcceptor: VsockDataConnectionAccepting {
        private let fds = Mutex<[Int32]>([])
        var accepted: [Int32] { fds.withLock { $0 } }

        nonisolated func acceptDataConnection(fd: Int32) {
            fds.withLock { $0.append(fd) }
        }
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
        try expectPeerOpen(b)
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

        try expectPeerClosed(b)
    }
}
