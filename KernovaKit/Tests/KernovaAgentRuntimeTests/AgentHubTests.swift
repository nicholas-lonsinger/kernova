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
        let transport = TestTransport()
        hub.attach(transport, policy: PolicySnapshot(), republisher: GuestLogRepublisher(logger: Fixture.logger))
        await flush(hub.queue)
        guard let peer = transport.connect() else {
            Issue.record("the transport refused a connection")
            return
        }
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
        #expect(summary.standing == .outdated(offeredVersionLabel: "next"))
        #expect(summary.isResponsive)
        driver.close(.shuttingDown)
        _ = await waiter.next { $0.peers.isEmpty }
        hub.close()
    }
    #endif

    @Test(
        "A peer stands current, outdated, or — offered nothing — not judged at all",
        arguments: [
            (hash: UInt8(0xA1), scope: InstallScope.user, standing: PeerSummary.Standing.current),
            (hash: UInt8(0xA2), scope: InstallScope.user, standing: .outdated(offeredVersionLabel: "next")),
            (hash: UInt8(0xA1), scope: InstallScope.unspecified, standing: .notOffered),
        ])
    func standing(_ expected: (hash: UInt8, scope: InstallScope, standing: PeerSummary.Standing)) async {
        let manifest = UpdateManifestValue(
            payloadHash: Data(repeating: expected.hash, count: 32), payloadSize: 1, format: .executable,
            versionLabel: "next")
        let harness = HubHarness(bundles: [
            BundledPayload(os: .linux, architecture: .arm64, scope: .user, manifest: manifest)
        ])
        await harness.attached()
        var claim = PeerClaim.session(expected.scope, instance: 1)
        claim.payloadHash = Data(repeating: 0xA1, count: 32)
        let peer = HubPeer(harness, claim: claim)
        let snapshot = await harness.snapshot { $0.peers.count == 1 }
        #expect(snapshot.peers[0].standing == expected.standing)
        peer.driver.close(.shuttingDown)
        harness.hub.close()
    }

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
        let sessionEvents = Recorder<PeerEvent>()
        let systemEvents = Recorder<PeerEvent>()
        let session = harness.runtime(registry: PeerFeatureRegistry(logs: LogForwarding()), events: sessionEvents)
        let system = harness.runtime(
            claim: PeerClaim(role: .systemPeer, scope: .system, os: .linux, architecture: .arm64),
            state: PeerSessionState(console: .off), registry: PeerFeatureRegistry(logs: LogForwarding()),
            events: systemEvents)
        session.start()
        system.start()
        var sessionPolicies = sessionEvents.waiter()
        var systemPolicies = systemEvents.waiter()
        _ = await sessionPolicies.next { $0 == .policyReceived }
        _ = await systemPolicies.next { $0 == .policyReceived }
        let before = await harness.snapshot { $0.peers.count == 2 }
        #expect(before.features[.logs] == .absent(.disabledByPolicy, debugDetail: ""))

        harness.hub.setPolicy(Fixture.logsEnabled)
        _ = await sessionPolicies.next { $0 == .policyReceived }
        _ = await systemPolicies.next { $0 == .policyReceived }
        _ = await harness.snapshot { $0.peers.count == 2 && $0.features[.logs].isAvailable }
        for connection in [1, 2] {
            #expect(
                harness.connector.commands.elements.filter { $0.connection == connection }.map(\.command)
                    .contains(.setPolicy(Fixture.logsEnabled)))
        }
        await withCheckedContinuation { continuation in session.close { continuation.resume() } }
        await withCheckedContinuation { continuation in system.close { continuation.resume() } }
        harness.hub.close()
    }

    @Test("Attaching a second transport ends the first one's connections once, and builds the next with its policy")
    func attachReplacesTransport() async {
        let harness = HubHarness()
        await harness.attached()
        let first = HubPeer(harness, claim: .session(.user, instance: 1))
        _ = await harness.snapshot { $0.peers.count == 1 }
        let firstAcceptor = harness.transport.acceptor

        let second = TestTransport()
        harness.hub.attach(second, policy: Fixture.logsEnabled, republisher: harness.republisher)
        await flush(harness.hub.queue)
        #expect(await first.closure() == .transportLost)
        _ = await harness.snapshot { $0.peers.isEmpty }
        #expect(harness.transport.stops.withLock { $0 } == 1)
        #expect(harness.transport.connect() == nil)

        let next = HubPeer(second, claim: .session(.user, instance: 2))
        _ = await harness.snapshot { $0.peers.count == 1 && $0.peers[0].handle.rawValue == 2 }
        await flush(harness.hub.queue)
        #expect(harness.connector.closures == [1: 1])
        #expect(firstAcceptor?.liveConnectionCount == 0)
        #expect(harness.connector.policies.elements.last?.connection == 2)
        #expect(harness.connector.policies.elements.last?.policy == Fixture.logsEnabled)
        next.driver.close(.shuttingDown)
        harness.hub.close()
    }

    @Test("Closing detaches the transport and refuses every later attach")
    func closeRefusesAttach() async {
        let harness = HubHarness()
        await harness.attached()
        let peer = HubPeer(harness, claim: .session(.user, instance: 1))
        _ = await harness.snapshot { $0.peers.count == 1 }

        harness.hub.close()
        #expect(await peer.closure() == .transportLost)
        let later = TestTransport()
        harness.hub.attach(later, policy: PolicySnapshot(), republisher: harness.republisher)
        await flush(harness.hub.queue)
        #expect(later.acceptor == nil)
        #expect(harness.transport.connect() == nil)
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
        #expect(harness.transport.acceptor?.liveConnectionCount == 0)
        #expect(harness.connect() == nil)
        harness.hub.close()
    }

    // MARK: Logs

    @Test("Forwarded records are republished behind their source's prefix, and a drop is a notice beside them")
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
        let republished = harness.guestLogs.elements
        #expect(republished[0].level == .notice)
        #expect(
            republished[0].segments == [
                LogSegment(text: "[session 1] ", isPrivate: false),
                LogSegment(text: "Dropped 45 log record(s) while the host was behind", isPrivate: false),
            ])
        #expect(republished[1].level == .info)
        #expect(republished[1].segments.map(\.text) == ["[session 1 app.kernova.tests/Flood] ", "record 45"])
        #expect(harness.hostLogs.elements.isEmpty)

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

    @Test(
        "A logger's records follow the policy: off discards what the ring held and every later one, on forwards them with their level and privacy"
    )
    func forwardingFollowsPolicy() async {
        let harness = HubHarness()
        await harness.attached()
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
        _ = await policies.next { $0 == .policyReceived }
        append("appended while off")

        harness.hub.setPolicy(Fixture.logsEnabled)
        _ = await policies.next { $0 == .policyReceived }
        append("appended while on")
        var guestLogs = harness.guestLogs.waiter()
        _ = await guestLogs.next { $0.segments.contains { $0.text == "appended while on" } }

        harness.hub.setPolicy(PolicySnapshot())
        _ = await policies.next { $0 == .policyReceived }
        append("appended while off again")
        harness.hub.setPolicy(Fixture.logsEnabled)
        _ = await policies.next { $0 == .policyReceived }
        append("appended while on again")
        _ = await guestLogs.next { $0.segments.contains { $0.text == "appended while on again" } }

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
        await withCheckedContinuation { continuation in session.close { continuation.resume() } }
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

    @Test("The ninth connection is refused before anything touches it, and a release frees a slot")
    func capAtAccept() {
        let probe = Probe()
        let ends = (0..<GuestStreamAcceptor.connectionLimit).compactMap { _ in probe.offer() }
        #expect(ends.count == 8)
        #expect(probe.acceptor.liveConnectionCount == 8)

        let opened = Locked(false)
        #expect(
            !probe.acceptor.offer { _ in
                opened.withLock { $0 = true }
                return nil
            })
        #expect(!opened.withLock { $0 })

        ends[0].shutdown()
        #expect(probe.acceptor.liveConnectionCount == 7)
        #expect(probe.offer() != nil)
        #expect(probe.accepted.elements.count == 9)
        probe.acceptor.stop()
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

    @Test("Stopping shuts down every live stream and refuses later connections")
    func stopShutsDown() {
        let probe = Probe()
        let host = probe.offer()
        probe.acceptor.stop()
        #expect(host?.shutdowns.withLock { $0 } == 1)
        #expect(probe.acceptor.liveConnectionCount == 0)
        let opened = Locked(false)
        #expect(
            !probe.acceptor.offer { _ in
                opened.withLock { $0 = true }
                return nil
            })
        #expect(!opened.withLock { $0 })
    }

    @Test("A stop landing while a stream is built shuts that stream down, hands it to nothing, and frees its slot")
    func stoppedWhileBuilding() {
        let probe = Probe()
        let (host, _) = MemoryStream.pair()
        let admitted = probe.acceptor.offer { released in
            host.onRelease(released)
            probe.acceptor.stop()
            return host
        }
        #expect(!admitted)
        #expect(probe.accepted.elements.isEmpty)
        #expect(host.shutdowns.withLock { $0 } == 1)
        #expect(probe.acceptor.liveConnectionCount == 0)
    }

    @Test("A stream that cannot be built gives its slot back")
    func failedOpenReleases() {
        let probe = Probe()
        #expect(!probe.acceptor.offer { _ in nil })
        #expect(probe.acceptor.liveConnectionCount == 0)
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
