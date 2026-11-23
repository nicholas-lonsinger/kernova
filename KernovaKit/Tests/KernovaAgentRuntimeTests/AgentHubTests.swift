#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaLogging
import KernovaPortableTestSupport
import KernovaSynchronization
import KernovaWire
import Testing

/// The agent hub against real peer runtimes and endpoints, over in-memory streams, on the platform clock.
@Suite("Agent hub")
struct AgentHubTests {
    static let manifest = UpdateManifestValue(
        payloadHash: Data(repeating: 0xB2, count: 32), payloadSize: 1, format: .executable, versionLabel: "next")

    @Test(
        "A peer stands current on the bundled payload, outdated on another one whether or not it is offered in band, and is not judged without a matching bundle; the hub withholds updates where its matching bundle is not offered",
        arguments: [
            (
                hash: UInt8(0xA1), scope: InstallScope.user, inBand: true, standing: PeerSummary.Standing.current,
                withheld: false
            ),
            (
                hash: UInt8(0xA2), scope: InstallScope.user, inBand: true,
                standing: .outdated(offeredVersionLabel: "next", update: .unavailable), withheld: false
            ),
            (hash: UInt8(0xA1), scope: InstallScope.unspecified, inBand: true, standing: .notOffered, withheld: false),
            (hash: UInt8(0xA1), scope: InstallScope.user, inBand: false, standing: .current, withheld: true),
            (
                hash: UInt8(0xA2), scope: InstallScope.user, inBand: false,
                standing: .outdated(offeredVersionLabel: "next", update: .notTeamSigned), withheld: true
            ),
            (hash: UInt8(0xA2), scope: InstallScope.unspecified, inBand: false, standing: .notOffered, withheld: false),
        ])
    func standing(
        _ expected: (
            hash: UInt8, scope: InstallScope, inBand: Bool, standing: PeerSummary.Standing, withheld: Bool
        )
    ) async throws {
        let manifest = UpdateManifestValue(
            payloadHash: Data(repeating: expected.hash, count: 32), payloadSize: 1, format: .executable,
            versionLabel: "next")
        let harness = HubHarness(bundles: [
            BundledPayload(
                os: .linux, architecture: .arm64, scope: .user, manifest: manifest, updatesInBand: expected.inBand)
        ])
        try await harness.attached()
        var claim = PeerClaim.session(expected.scope, instance: 1)
        claim.payloadHash = Data(repeating: 0xA1, count: 32)
        let peer = HubPeer(harness, claim: claim)
        let snapshot = try await harness.snapshot { $0.peers.count == 1 }
        #expect(snapshot.peers[0].standing == expected.standing)
        #expect(snapshot.inBandUpdatesWithheld == expected.withheld)
        peer.driver.close(.shuttingDown)
        harness.hub.close()
    }

    // MARK: In-band update

    static let offered = BundledPayload(
        os: .linux, architecture: .arm64, scope: .user,
        manifest: UpdateManifestValue(
            payloadHash: Data(repeating: 0xB2, count: 32), payloadSize: 100_000, format: .executable,
            versionLabel: "next"),
        updatesInBand: true)

    static func inBandUpdate(_ snapshot: AgentHubSnapshot) -> PeerSummary.InBandUpdate? {
        guard case .outdated(_, let update)? = snapshot.peers.first?.standing else { return nil }
        return update
    }

    @Test("An outdated peer whose pull of the offered payload ends without installing it reads failed")
    func failedPull() async throws {
        // FixedPayloads fails every read, so the host resets the pull READ_FAILED.
        let harness = HubHarness(bundles: [Self.offered])
        try await harness.attached()
        let peer = HubPeer(
            harness, claim: .session(.user, instance: 1), update: .available(UpdateOffer(formats: [.executable])))
        _ = try await harness.snapshot { Self.inBandUpdate($0) == .failed }
        peer.driver.close(.shuttingDown)
        harness.hub.close()
    }

    @Test(
        "An outdated peer that refuses the offered hash reads failed, or launch-refused for UPDATE_LAUNCH_REFUSED; one that cannot take its format, unavailable",
        arguments: [
            (
                UpdateOffer(formats: [.executable], rejected: RejectedPayload(hash: Data(repeating: 0xB2, count: 32))),
                .failed
            ),
            (
                UpdateOffer(
                    formats: [.executable],
                    rejected: RejectedPayload(hash: Data(repeating: 0xB2, count: 32), code: .updateHashMismatch)),
                .failed
            ),
            (
                UpdateOffer(
                    formats: [.executable],
                    rejected: RejectedPayload(hash: Data(repeating: 0xB2, count: 32), code: .updateLaunchRefused)),
                .launchRefused
            ),
            (UpdateOffer(formats: [.paxTree]), PeerSummary.InBandUpdate.unavailable),
        ])
    func refusedOffer(offer: UpdateOffer, expected: PeerSummary.InBandUpdate) async throws {
        let harness = HubHarness(bundles: [Self.offered], payloadSource: ZeroPayloads())
        try await harness.attached()
        let peer = HubPeer(harness, claim: .session(.user, instance: 1), update: .available(offer))
        _ = try await harness.snapshot { Self.inBandUpdate($0) == expected }
        #expect(
            !harness.connector.events.elements.contains { if case .role(.update) = $0.event { true } else { false } })
        peer.driver.close(.shuttingDown)
        harness.hub.close()
    }

    @Test(
        "A pull the peer refuses on this connection reads launch-refused for UPDATE_LAUNCH_REFUSED, else failed",
        arguments: [
            (ErrorCode.updateLaunchRefused, PeerSummary.InBandUpdate.launchRefused), (.updateHashMismatch, .failed),
        ])
    func refusedPull(code: ErrorCode, expected: PeerSummary.InBandUpdate) async throws {
        let harness = HubHarness(bundles: [Self.offered], payloadSource: ZeroPayloads())
        try await harness.attached()
        let peer = HubPeer(
            harness, claim: .session(.user, instance: 1), update: .available(UpdateOffer(formats: [.executable])),
            refuses: code)
        var events = harness.connector.events.waiter()
        let result = try await events.next { if case .role(.update(.result)) = $0.event { true } else { false } }
        guard case .role(.update(.result(_, let value))) = result.event else {
            Issue.record("no result")
            return
        }
        #expect(value.kind == .rejected)
        #expect(value.error?.code == code)
        _ = try await harness.snapshot { Self.inBandUpdate($0) == expected }
        peer.driver.close(.shuttingDown)
        harness.hub.close()
    }

    // MARK: Commands

    @Test("Freezing and thawing reach every connection, and one accepted while frozen")
    func freezingReachesEveryDriver() async throws {
        let harness = HubHarness()
        try await harness.attached()
        let first = HubPeer(harness, claim: .session(.user, instance: 1), state: PeerSessionState(sessionID: "1"))
        let second = HubPeer(harness, claim: .session(.user, instance: 2), state: PeerSessionState(sessionID: "2"))
        _ = try await harness.snapshot { $0.peers.count == 2 }

        harness.hub.setGuestFrozen(true)
        let third = HubPeer(harness, claim: .session(.user, instance: 3), state: PeerSessionState(sessionID: "3"))
        _ = try await harness.snapshot { $0.peers.count == 3 }
        harness.hub.setGuestFrozen(false)
        try await flush(harness.hub.queue)

        let commands = harness.connector.commands.elements
        for connection in 1...3 {
            let sent = commands.filter { $0.connection == connection }.map(\.command)
            #expect(sent.filter { $0 == .setPeerFrozen(true) }.count == 1)
            #expect(sent.last == .setPeerFrozen(false))
        }
        for peer in [first, second, third] { peer.driver.close(.shuttingDown) }
        harness.hub.close()
    }

    // MARK: Logs

    @Test(
        "A logger's records follow the policy: off discards what the ring held and every later one, on forwards them with their level and privacy"
    )
    func forwardingFollowsPolicy() async throws {
        let harness = HubHarness()
        try await harness.attached()
        let logs = LogForwarding()
        // The path the shell installs: a logger whose records go through the forwarding sink.
        let agentLogger = KernovaLogger(subsystem: "app.kernova.agent", category: "Agent", sink: logs.sink)
        func append(_ text: String) {
            agentLogger.log(.error, "\(text, privacy: .public) for \("pbear", privacy: .private)")
        }
        let events = Recorder<PeerEvent>()
        var policies = events.waiter()
        // Buffering: nothing has decided yet.
        append("buffered before any policy")
        let session = harness.runtime(registry: PeerFeatureRegistry(logs: logs), events: events)
        session.start()
        _ = try await policies.next { $0.isPolicyReceived }
        append("appended while off")

        harness.hub.setPolicy(Fixture.logsEnabled)
        _ = try await policies.next { $0 == .role(.policyReceived(Fixture.logsEnabled)) }
        append("appended while on")
        var guestLogs = harness.guestLogs.waiter()
        _ = try await guestLogs.next { $0.segments.contains { $0.text == "appended while on" } }

        harness.hub.setPolicy(PolicySnapshot())
        _ = try await policies.next { $0 == .role(.policyReceived(PolicySnapshot())) }
        append("appended while off again")
        harness.hub.setPolicy(Fixture.logsEnabled)
        _ = try await policies.next { $0 == .role(.policyReceived(Fixture.logsEnabled)) }
        append("appended while on again")
        _ = try await guestLogs.next { $0.segments.contains { $0.text == "appended while on again" } }

        #expect(
            harness.guestLogs.elements.map(\.level) == [.error, .error])
        #expect(
            harness.guestLogs.elements.map(\.segments)
                == ["appended while on", "appended while on again"].map {
                    [
                        LogSegment(text: "[session 1 app.kernova.agent/Agent] ", isPrivate: false),
                        LogSegment(text: $0, isPrivate: false), LogSegment(text: " for ", isPrivate: false),
                        LogSegment(text: "pbear", isPrivate: true),
                    ]
                })
        try await Backstop("session.close").park { resume in session.close { resume(()) } }
        harness.hub.close()
    }
}

/// The hub's admission of a transport's connections.
@Suite("Guest stream acceptor")
struct GuestStreamAcceptorTests {
    /// An acceptor counting what it hands on, with its notices recorded.
    final class Probe: Sendable {
        let accepted = Recorder<Int>()
        let notices: Recorder<(KernovaLogLevel, String)>
        let acceptor: GuestStreamAcceptor

        init() {
            let (logger, notices) = Fixture.recordingLogger()
            self.notices = notices
            let accepted = accepted
            let count = Locked(0)
            acceptor = GuestStreamAcceptor(logger: logger) { _ in
                accepted.record(
                    count.withLock { count in
                        count += 1
                        return count
                    })
            }
        }

        /// Offers a connection over a fresh in-memory pair, answering its host end when accepted.
        func offer() -> MemoryStream? {
            let (host, _) = MemoryStream.pair()
            let admitted = acceptor.offer { released in
                host.onRelease(released)
                return host
            }
            return admitted ? host : nil
        }
    }

    @Test("A run of refusals at the cap is one notice, and the slot that ends it another")
    func refusalsLoggedOncePerRun() {
        let probe = Probe()
        let ends = (0..<GuestStreamAcceptor.connectionLimit).compactMap { _ in probe.offer() }
        for _ in 0..<5 { #expect(probe.offer() == nil) }
        #expect(probe.notices.elements.map(\.1).filter { $0.hasPrefix("Refusing") }.count == 1)

        ends[0].shutdown()
        #expect(
            probe.notices.elements.map(\.1).last
                == "An agent connection slot is free again, after 5 connection(s) were refused")
        #expect(probe.offer() != nil)
        #expect(probe.offer() == nil)
        #expect(probe.notices.elements.map(\.1).filter { $0.hasPrefix("Refusing") }.count == 2)
        probe.acceptor.stop()
    }
}

extension ConnectionClosure {
    fileprivate var code: ErrorCode? {
        switch self {
        case .closedByPeer(let error), .closedLocally(let error): error.code
        case .transportLost, .notThisProtocol: nil
        }
    }

    fileprivate var retryAfter: CoreDuration? {
        switch self {
        case .closedByPeer(let error), .closedLocally(let error): error.retryAfter
        case .transportLost, .notThisProtocol: nil
        }
    }
}
