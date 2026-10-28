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
import KernovaSynchronization
import KernovaWire
import Testing

/// The agent hub against real peer runtimes and endpoints, over in-memory streams, on the platform clock.
@Suite("Agent hub")
struct AgentHubTests {
    static let manifest = UpdateManifestValue(
        payloadHash: Data(repeating: 0xB2, count: 32), payloadSize: 1, format: .executable, versionLabel: "next")

    #if canImport(Darwin)
    @Test("A peer's Hello reaches the main actor as one peer, judged against the payload it is offered")
    func helloOnTheMainActor() async {
        let snapshots = Recorder<AgentHubSnapshot>()
        let hub = AgentHub(
            claim: Fixture.hostClaim, policy: PolicySnapshot(),
            payloads: FixedPayloads(bundles: [
                BundledPayload(os: .linux, architecture: .arm64, scope: .user, manifest: Self.manifest)
            ]), logger: Fixture.logger
        ) { snapshot in
            MainActor.assumeIsolated { snapshots.record(snapshot) }
        }
        let transport = GuestStreamAcceptor()
        hub.attach(transport, policy: PolicySnapshot(), republisher: GuestLogRepublisher(logger: Fixture.logger))
        await flush(hub.queue)
        let (host, peer) = MemoryStream.pair()
        #expect(
            transport.offer { released in
                host.onRelease(released)
                return host
            })
        let driver = ConnectionDriver(
            endpoint: PeerEndpoint(
                Fixture.peerConfiguration(), generation: ConnectionGeneration(rawValue: 1),
                now: SystemScheduler().now),
            stream: peer, scheduler: SystemScheduler(), logger: Fixture.logger,
            handlers: ConnectionDriver<PeerEndpoint>.Handlers(event: { _, _ in }))
        driver.start()

        var waiter = snapshots.waiter()
        let snapshot = await waiter.next { !$0.peers.isEmpty }
        let summary = snapshot.peers[0]
        #expect(summary.role == .sessionPeer)
        #expect(summary.scope == .user)
        #expect(summary.sessionID == Fixture.peerState.sessionID)
        #expect(summary.userName == Fixture.peerState.userName)
        #expect(summary.console == .on)
        #expect(summary.versionLabel == "peer")
        #expect(!summary.isCurrent)
        #expect(summary.offeredVersionLabel == "next")
        #expect(summary.isResponsive)
        driver.close(.shuttingDown)
        _ = await waiter.next { $0.peers.isEmpty }
        hub.close()
    }
    #endif

    // MARK: Identity conflicts (spec §4.5)

    @Test("Row 1: the same process's new connection supersedes its old one")
    func sameInstanceSupersedes() async {
        let harness = HubHarness()
        await harness.attached()
        let first = HubPeer(harness, claim: .session(.user, instance: 1))
        _ = await harness.snapshot { $0.peers.count == 1 }
        let second = HubPeer(harness, claim: .session(.user, instance: 1))

        let closure = await first.closure()
        #expect(closure.code == .superseded)
        #expect(closure.retryAfter == nil)
        let settled = await harness.snapshot { $0.peers.count == 1 && $0.peers[0].handle.rawValue == 2 }
        #expect(settled.peers.count == 1)
        second.driver.close(.shuttingDown)
        harness.hub.close()
    }

    @Test(
        "Row 2: of two session peers of different scope rank, the lower closes DUPLICATE_PEER, 60 s",
        arguments: [
            (existing: InstallScope.user, incoming: InstallScope.unspecified),
            (existing: InstallScope.unspecified, incoming: InstallScope.user),
            (existing: InstallScope.user, incoming: InstallScope.system),
        ])
    func lowerRankCloses(_ scopes: (existing: InstallScope, incoming: InstallScope)) async {
        let harness = HubHarness()
        await harness.attached()
        let existing = HubPeer(harness, claim: .session(scopes.existing, instance: 1))
        _ = await harness.snapshot { $0.peers.count == 1 }
        let incoming = HubPeer(harness, claim: .session(scopes.incoming, instance: 2))

        let rank: [InstallScope: Int] = [.user: 2, .system: 1, .unspecified: 0]
        let existingWins = rank[scopes.existing]! > rank[scopes.incoming]!
        let winningScope = existingWins ? scopes.existing : scopes.incoming
        let loser = existingWins ? incoming : existing
        let winner = existingWins ? existing : incoming
        let closure = await loser.closure()
        #expect(closure.code == .duplicatePeer)
        #expect(closure.retryAfter == .milliseconds(60_000))
        _ = await harness.snapshot { $0.peers.count == 1 && $0.peers[0].scope == winningScope }
        winner.driver.close(.shuttingDown)
        harness.hub.close()
    }

    @Test("Row 3: an unresponsive existing peer is superseded by an incoming one of equal rank")
    func unresponsiveExistingSuperseded() async {
        var policy = ReceiverPolicy.production
        policy.pingInterval = .milliseconds(50)
        policy.unresponsiveAfter = .milliseconds(300)
        policy.expiryConfirmation = .milliseconds(10)
        let harness = HubHarness(receiverPolicy: policy)
        await harness.attached()
        let existing = HubPeer(harness, claim: .session(.user, instance: 1))
        _ = await harness.snapshot { $0.peers.count == 1 }
        existing.stream.holdOutbound()
        _ = await harness.snapshot { $0.peers.count == 1 && !$0.peers[0].isResponsive }
        let incoming = HubPeer(harness, claim: .session(.user, instance: 2))

        let closure = await existing.closure()
        #expect(closure.code == .superseded)
        #expect(closure.retryAfter == nil)
        _ = await harness.snapshot { $0.peers.count == 1 && $0.peers[0].handle.rawValue == 2 }
        incoming.driver.close(.shuttingDown)
        harness.hub.close()
    }

    @Test("Row 4: a responsive existing peer stays; the incoming one closes DUPLICATE_PEER, 20 s")
    func responsiveExistingStays() async {
        let harness = HubHarness()
        await harness.attached()
        let existing = HubPeer(harness, claim: .session(.user, instance: 1))
        _ = await harness.snapshot { $0.peers.count == 1 }
        let incoming = HubPeer(harness, claim: .session(.user, instance: 2))

        let closure = await incoming.closure()
        #expect(closure.code == .duplicatePeer)
        #expect(closure.retryAfter == .milliseconds(20_000))
        await flush(harness.hub.queue)
        #expect(harness.connector.closures == [2: 1])
        #expect(harness.snapshots.elements.last?.peers.map(\.handle) == [PeerHandle(rawValue: 1)])
        existing.driver.close(.shuttingDown)
        harness.hub.close()
    }

    @Test("Two session peers of different sessions are both peers")
    func differentSessionsCoexist() async {
        let harness = HubHarness()
        await harness.attached()
        let first = HubPeer(harness, claim: .session(.user, instance: 1), state: PeerSessionState(sessionID: "1"))
        let second = HubPeer(harness, claim: .session(.user, instance: 2), state: PeerSessionState(sessionID: "2"))
        let snapshot = await harness.snapshot { $0.peers.count == 2 }
        #expect(Set(snapshot.peers.map(\.sessionID)) == ["1", "2"])
        first.driver.close(.shuttingDown)
        second.driver.close(.shuttingDown)
        harness.hub.close()
    }

    // MARK: Merged status

    @Test("The merged status follows 0, 1 and 2 peers, newest first")
    func mergedStatus() async {
        let harness = HubHarness()
        await harness.attached()
        let session = harness.runtime(registry: PeerFeatureRegistry(power: FakePowerAdapter()))
        session.start()
        let one = await harness.snapshot { $0.peers.count == 1 && $0.features[.power].isAvailable }
        #expect(one.peers[0].role == .sessionPeer)

        let system = harness.runtime(
            claim: PeerClaim(role: .systemPeer, scope: .system, os: .linux, architecture: .arm64),
            state: PeerSessionState(console: .off))
        system.start()
        let two = await harness.snapshot { $0.peers.count == 2 }
        #expect(two.peers.map(\.role) == [.systemPeer, .sessionPeer])
        #expect(two.features[.power].isAvailable)

        await withCheckedContinuation { continuation in session.close { continuation.resume() } }
        let systemOnly = await harness.snapshot { $0.peers.count == 1 && $0.peers[0].role == .systemPeer }
        guard case .absent(.notImplemented, _) = systemOnly.features[.power] else {
            Issue.record("power with only the system peer: \(systemOnly.features[.power])")
            return
        }

        await withCheckedContinuation { continuation in system.close { continuation.resume() } }
        let none = await harness.snapshot { $0.peers.isEmpty && $0 != systemOnly }
        for entry in none.features.entries {
            #expect(entry.status == .absent(.noAgent, debugDetail: ""))
        }
        harness.hub.close()
    }

    // MARK: Commands

    @Test("A policy toggle reaches every connection as a PolicyUpdate")
    func policyReachesPeers() async {
        let harness = HubHarness()
        await harness.attached()
        let events = Recorder<PeerEvent>()
        let runtime = harness.runtime(registry: PeerFeatureRegistry(logs: LogForwarding()), events: events)
        runtime.start()
        var waiter = events.waiter()
        _ = await waiter.next { $0 == .policyReceived }
        let before = await harness.snapshot { $0.peers.count == 1 }
        #expect(before.features[.logs] == .absent(.disabledByPolicy, debugDetail: ""))

        harness.hub.setPolicy(Fixture.logsEnabled)
        _ = await waiter.next { $0 == .policyReceived }
        _ = await harness.snapshot { $0.peers.count == 1 && $0.features[.logs].isAvailable }
        #expect(harness.connector.commands.elements.map(\.command).contains(.setPolicy(Fixture.logsEnabled)))
        await withCheckedContinuation { continuation in runtime.close { continuation.resume() } }
        harness.hub.close()
    }

    @Test("Freezing and thawing reach every connection, and one accepted while frozen")
    func freezingReachesEveryDriver() async {
        let harness = HubHarness()
        await harness.attached()
        let first = HubPeer(harness, claim: .session(.user, instance: 1), state: PeerSessionState(sessionID: "1"))
        let second = HubPeer(harness, claim: .session(.user, instance: 2), state: PeerSessionState(sessionID: "2"))
        _ = await harness.snapshot { $0.peers.count == 2 }

        harness.hub.setGuestFrozen(true)
        let third = HubPeer(harness, claim: .session(.user, instance: 3), state: PeerSessionState(sessionID: "3"))
        _ = await harness.snapshot { $0.peers.count == 3 }
        harness.hub.setGuestFrozen(false)
        await flush(harness.hub.queue)

        let commands = harness.connector.commands.elements
        for connection in 1...3 {
            let sent = commands.filter { $0.connection == connection }.map(\.command)
            #expect(sent.filter { $0 == .setPeerFrozen(true) }.count == 1)
            #expect(sent.last == .setPeerFrozen(false))
        }
        for peer in [first, second, third] { peer.driver.close(.shuttingDown) }
        harness.hub.close()
    }

    @Test("Detaching ends every connection exactly once and frees every slot")
    func detachEndsEveryDriverOnce() async {
        let harness = HubHarness()
        await harness.attached()
        let first = HubPeer(harness, claim: .session(.user, instance: 1), state: PeerSessionState(sessionID: "1"))
        let second = HubPeer(harness, claim: .session(.user, instance: 2), state: PeerSessionState(sessionID: "2"))
        _ = await harness.snapshot { $0.peers.count == 2 }

        harness.hub.detach()
        #expect(await first.closure() == .transportLost)
        #expect(await second.closure() == .transportLost)
        _ = await harness.snapshot { $0.peers.isEmpty }
        var events = harness.connector.events.waiter()
        for _ in 1...2 { _ = await events.next { if case .closed = $0.event { true } else { false } } }
        await flush(harness.hub.queue)
        #expect(harness.connector.closures == [1: 1, 2: 1])
        #expect(harness.transport.liveConnectionCount == 0)
        #expect(harness.connect() == nil)
        harness.hub.close()
    }

    // MARK: Logs

    @Test("Forwarded records are republished behind their source's prefix, and a drop is a host notice")
    func logsRepublished() async {
        let harness = HubHarness(policy: Fixture.logsEnabled)
        await harness.attached()
        let logs = LogForwarding()
        for index in 0..<300 {
            logs.append(
                LogRecordValue(
                    timestampMilliseconds: 0, level: .info, subsystem: "app.kernova.tests", category: "Flood",
                    segments: [LogSegmentValue(text: "record \(index)")]))
        }
        logs.append(
            LogRecordValue(
                timestampMilliseconds: 0, level: .unspecified, subsystem: "app.kernova.tests", category: "Last",
                segments: [LogSegmentValue(text: "visible "), LogSegmentValue(text: "secret", isPrivate: true)]))
        let session = harness.runtime(registry: PeerFeatureRegistry(logs: logs))
        session.start()

        var guestLogs = harness.guestLogs.waiter()
        let last = await guestLogs.next {
            $0.segments.first?.text.hasPrefix("[session 1 app.kernova.tests/Last]") == true
        }
        #expect(last.level == .notice)
        #expect(
            last.segments == [
                LogSegment(text: "[session 1 app.kernova.tests/Last] ", isPrivate: false),
                LogSegment(text: "visible ", isPrivate: false), LogSegment(text: "secret", isPrivate: true),
            ])
        let first = harness.guestLogs.elements[0]
        #expect(first.level == .info)
        #expect(first.segments.map(\.text) == ["[session 1 app.kernova.tests/Flood] ", "record 45"])
        var hostLogs = harness.hostLogs.waiter()
        #expect(
            await hostLogs.next { $0.hasPrefix("Guest") }
                == "Guest session dropped 45 log record(s) while the host was behind")

        let systemLogs = LogForwarding()
        systemLogs.append(
            LogRecordValue(
                timestampMilliseconds: 0, level: .error, subsystem: "app.kernova.agent", category: "Power",
                segments: [LogSegmentValue(text: "system record")]))
        let system = harness.runtime(
            claim: PeerClaim(role: .systemPeer, scope: .system, os: .linux, architecture: .arm64),
            state: PeerSessionState(console: .off), registry: PeerFeatureRegistry(logs: systemLogs))
        system.start()
        let systemRecord = await guestLogs.next { $0.segments.last?.text == "system record" }
        #expect(systemRecord.level == .error)
        #expect(systemRecord.segments[0] == LogSegment(text: "[system app.kernova.agent/Power] ", isPrivate: false))

        await withCheckedContinuation { continuation in session.close { continuation.resume() } }
        await withCheckedContinuation { continuation in system.close { continuation.resume() } }
        harness.hub.close()
    }
}

/// The transport's admission, through its seam for connections.
@Suite("Guest stream acceptor")
struct GuestStreamAcceptorTests {
    @Test("The ninth connection is refused before anything touches it, and a release frees a slot")
    func capAtAccept() async {
        let acceptor = GuestStreamAcceptor()
        let accepted = Recorder<Int>()
        let count = Locked(0)
        acceptor.start { _ in
            accepted.record(
                count.withLock {
                    $0 += 1; return $0
                })
        }
        var ends: [MemoryStream] = []
        for _ in 0..<GuestStreamAcceptor.connectionLimit {
            let (host, peer) = MemoryStream.pair()
            #expect(
                acceptor.offer { released in
                    host.onRelease(released)
                    return host
                })
            ends.append(host)
            _ = peer
        }
        #expect(acceptor.liveConnectionCount == 8)

        let opened = Locked(false)
        #expect(
            !acceptor.offer { _ in
                opened.withLock { $0 = true }
                return nil
            })
        #expect(!opened.withLock { $0 })

        ends[0].shutdown()
        #expect(acceptor.liveConnectionCount == 7)
        let (host, _) = MemoryStream.pair()
        #expect(
            acceptor.offer { released in
                host.onRelease(released)
                return host
            })
        #expect(accepted.elements.count == 9)
        acceptor.stop()
    }

    @Test("Stopping shuts down every live stream and refuses later connections")
    func stopShutsDown() {
        let acceptor = GuestStreamAcceptor()
        acceptor.start { _ in }
        let (host, _) = MemoryStream.pair()
        #expect(
            acceptor.offer { released in
                host.onRelease(released)
                return host
            })
        acceptor.stop()
        #expect(host.shutdowns.withLock { $0 } == 1)
        #expect(acceptor.liveConnectionCount == 0)
        let opened = Locked(false)
        #expect(
            !acceptor.offer { _ in
                opened.withLock { $0 = true }
                return nil
            })
        #expect(!opened.withLock { $0 })
    }

    @Test("A stream that cannot be built gives its slot back")
    func failedOpenReleases() {
        let acceptor = GuestStreamAcceptor()
        acceptor.start { _ in }
        #expect(!acceptor.offer { _ in nil })
        #expect(acceptor.liveConnectionCount == 0)
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
