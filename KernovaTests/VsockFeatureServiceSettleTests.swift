import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Every host-side service conforming to `VsockFeatureService`.
///
/// A case per service rather than a table of closures, so each service's three
/// assertions arrive as three named test cases.
private enum ServiceKind: String, CaseIterable, Sendable, CustomStringConvertible {
    case control
    case log
    case drop
    case clipboard

    var description: String { rawValue }
}

/// The settle contract itself, asserted once per conforming service rather than
/// inside each service's own suite: a fifth feature channel that forgets to
/// notify its owner fails here instead of shipping.
@Suite("Vsock feature service settle contract", .admissionGated)
@MainActor
struct VsockFeatureServiceSettleTests {
    // MARK: - Harness

    /// Builds `kind` over `channel`, with a label unique to this case so a
    /// service keying staging on it cannot collide with a concurrent one.
    private func makeService(_ kind: ServiceKind, channel: VsockChannel)
        -> any VsockFeatureService
    {
        let label = "settle-\(kind)-\(UUID().uuidString)"
        switch kind {
        case .control:
            return VsockControlService(channel: channel, label: label)
        case .log:
            return VsockGuestLogService(channel: channel, label: label)
        case .drop:
            return VsockDropService(
                channel: channel, label: label, reporter: ClipboardTransferReporter())
        case .clipboard:
            return VsockClipboardService(
                channel: channel, label: label, reporter: ClipboardTransferReporter())
        }
    }

    /// One started service, the peer end standing in for the guest agent, and
    /// the recorder counting the service's channel-lost notifications.
    private struct Fixture {
        let service: any VsockFeatureService
        let peer: VsockChannel
        let lost: SettleRecorder
    }

    private func makeFixture(_ kind: ServiceKind) throws -> Fixture {
        let (hostFd, guestFd) = try makeRawSocketPair()
        let host = VsockChannel(fileDescriptor: hostFd)
        let peer = VsockChannel(fileDescriptor: guestFd)
        host.start()
        peer.start()
        let service = makeService(kind, channel: host)
        let lost = SettleRecorder()
        service.onChannelLost = { lost.record() }
        service.start()
        return Fixture(service: service, peer: peer, lost: lost)
    }

    // MARK: - The channel dying under the service

    @Test(
        "The peer closing the channel notifies the owner exactly once",
        arguments: ServiceKind.allCases)
    fileprivate func peerCloseNotifiesOwner(kind: ServiceKind) async throws {
        let fixture = try makeFixture(kind)
        defer { fixture.service.stop() }

        // The guest agent quits mid-session: EOF unwinds the service's loop.
        fixture.peer.close()

        try await fixture.lost.changed.wait { fixture.lost.count == 1 }
        #expect(fixture.lost.count == 1)
    }

    // MARK: - The owner asking

    @Test("An owner-requested stop() notifies nobody", arguments: ServiceKind.allCases)
    fileprivate func ownerStopIsSilent(kind: ServiceKind) async throws {
        let fixture = try makeFixture(kind)
        defer { fixture.peer.close() }

        // Session teardown, a live policy withdrawal, and the accept path's
        // replace-the-previous-service all route here. The owner already knows,
        // and telling it the channel "died" would have it react to a teardown it
        // asked for.
        fixture.service.stop()

        // RATIONALE: negative assertion ("prove the callback never fired") — a
        // fixed observation window, per docs/TESTING.md "Async waits in tests".
        // The service's own consume tail also unwinds in here, and its settle
        // must not fire the callback either: the owner's stop() latched first.
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.lost.count == 0)
    }

    @Test(
        "A stop() after the channel already died adds no second notification",
        arguments: ServiceKind.allCases)
    fileprivate func stopAfterChannelLossIsSilent(kind: ServiceKind) async throws {
        let fixture = try makeFixture(kind)

        fixture.peer.close()
        try await fixture.lost.changed.wait { fixture.lost.count == 1 }

        // The owner's teardown lands on an already-settled service — the shape
        // `stopVsockServices()` produces after a mid-session agent exit.
        fixture.service.stop()

        // RATIONALE: negative assertion ("prove no second callback fired") — a
        // fixed observation window, per docs/TESTING.md "Async waits in tests".
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.lost.count == 1)
    }
}

// MARK: - Settle recorder

/// Counts `onChannelLost` invocations. Main-bound because the callback is
/// `@MainActor` in production, not by convenience (docs/TESTING.md).
@MainActor
private final class SettleRecorder {
    private(set) var count = 0

    /// Fires on every `record`; await it instead of polling `count`.
    let changed = AsyncGate()

    func record() {
        count += 1
        changed.notify()
    }
}
