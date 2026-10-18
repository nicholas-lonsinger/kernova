import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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
@Suite("Vsock feature service settle contract", .caseScoped)
@MainActor
struct VsockFeatureServiceSettleTests {
    private let stagingRoot = TestStagingRoot()

    // MARK: - Harness

    /// Builds `kind` over `channel`, with a label unique to this case so a
    /// service keying staging on it cannot collide with a concurrent one, and
    /// how its readers learn whether it is connected — `nil` for the log
    /// service, which has no such reading.
    private func makeService(_ kind: ServiceKind, channel: VsockChannel)
        -> (any VsockFeatureService, isConnected: (@MainActor () -> Bool)?)
    {
        let label = "settle-\(kind)-\(UUID().uuidString)"
        switch kind {
        case .control:
            let service = VsockControlService(
                channel: channel, label: label, hostVersion: AppBundleProducts.testing.hostVersion,
                bundledAgentVersion: BundledGuestAgent.testing.version)
            return (service, { service.isConnected })
        case .log:
            return (VsockGuestLogService(channel: channel, label: label), nil)
        case .drop:
            let service = VsockDropService(
                channel: channel, label: label, reporter: ClipboardTransferReporter(),
                stagingRoot: stagingRoot.root, stagingKey: label)
            return (service, { service.isConnected })
        case .clipboard:
            let service = VsockClipboardService(
                channel: channel, label: label, reporter: ClipboardTransferReporter(),
                stagingRoot: stagingRoot.root, stagingKey: label)
            return (service, { service.isConnected })
        }
    }

    /// One started service, the peer end standing in for the guest agent, and
    /// the recorder counting the service's channel-lost notifications.
    private struct Fixture {
        let service: any VsockFeatureService
        let isConnected: (@MainActor () -> Bool)?
        let peer: VsockChannel
        let lost: ChannelLostRecorder
    }

    private func makeFixture(_ kind: ServiceKind) throws -> Fixture {
        let (host, peer) = try makeStartedChannelPair()
        let (service, isConnected) = makeService(kind, channel: host)
        let lost = ChannelLostRecorder()
        service.onChannelLost = { lost.record() }
        service.start()
        return Fixture(service: service, isConnected: isConnected, peer: peer, lost: lost)
    }

    /// Returns once nothing `tasks` started can still reach the owner: each task
    /// has ended, and so has the main-queue hop a clipboard endpoint's end takes
    /// (`ClipboardEndpoint.lifecycleTasksForTesting`).
    private func settled(_ tasks: [Task<Void, Never>]) async {
        for task in tasks { await task.value }
        await drainMainQueue()
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
        let tasks = fixture.service.lifecycleTasksForTesting

        // Session teardown, a live policy withdrawal, and the accept path's
        // replace-the-previous-service all route here. The owner already knows,
        // and telling it the channel "died" would have it react to a teardown it
        // asked for.
        fixture.service.stop()

        // The service's own consume tail also unwinds in here, and its settle
        // must not fire the callback either: the owner's stop() latched first.
        await settled(tasks)
        #expect(fixture.lost.count == 0)
    }

    @Test("start() after a settle does not reopen the service", arguments: ServiceKind.allCases)
    fileprivate func startAfterSettleIsANoOp(kind: ServiceKind) async throws {
        let fixture = try makeFixture(kind)
        defer { fixture.peer.close() }
        let tasks = fixture.service.lifecycleTasksForTesting

        fixture.service.stop()
        // Terminal, not merely idempotent: a reconnect is served by a fresh
        // instance. A service that reopened here would be draining an
        // already-closed channel, and that channel's immediate end would reach
        // the owner as a loss it never had a live connection for — after a
        // teardown the owner itself asked for.
        fixture.service.start()

        // The same tasks the first start() armed, cancelled and still held: no
        // second drain was armed.
        #expect(fixture.service.lifecycleTasksForTesting == tasks)
        #expect(fixture.isConnected?() != true)
        await settled(tasks)
        #expect(fixture.lost.count == 0)
    }

    @Test(
        "A stop() after the channel already died adds no second notification",
        arguments: ServiceKind.allCases)
    fileprivate func stopAfterChannelLossIsSilent(kind: ServiceKind) async throws {
        let fixture = try makeFixture(kind)
        let tasks = fixture.service.lifecycleTasksForTesting

        fixture.peer.close()
        try await fixture.lost.changed.wait { fixture.lost.count == 1 }

        // The owner's teardown lands on an already-settled service — the shape
        // `stopVsockServices()` produces after a mid-session agent exit.
        fixture.service.stop()

        await settled(tasks)
        #expect(fixture.lost.count == 1)
    }
}
