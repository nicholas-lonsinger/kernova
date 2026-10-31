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

/// Fixed bundles, whose bytes it never serves.
struct FixedPayloads: BundledPayloadProvider {
    let bundles: [BundledPayload]

    func loadPayloads(_ completion: @escaping @Sendable ([BundledPayload]) -> Void) {
        completion(bundles)
    }

    func read(
        manifest: UpdateManifestValue, offset: UInt64, count: Int,
        _ completion: @escaping @Sendable (Result<Data, WireError>) -> Void
    ) {
        completion(.failure(WireError(.readFailed)))
    }
}

/// The real host runtime, with every connection's commands and events recorded by connection number,
/// from 1 in accept order.
final class RecordingConnector: HostConnectionMaking {
    let runtime: HostConnectionRuntime
    let commands = Recorder<(connection: Int, command: HostCommand)>()
    let events = Recorder<(connection: Int, event: HostEvent)>()
    /// The policy each connection was built with.
    let policies = Recorder<(connection: Int, policy: PolicySnapshot)>()
    private let count = Locked(0)

    init(receiverPolicy: ReceiverPolicy) {
        runtime = HostConnectionRuntime(
            claim: Fixture.hostClaim, scheduler: SystemScheduler(), payloadSource: FixedPayloads(bundles: []),
            logger: Fixture.logger, receiverPolicy: receiverPolicy)
    }

    func makeConnection(
        _ stream: any ByteStream, policy: PolicySnapshot, bundles: [BundledPayload],
        deliveringOn queue: DispatchQueue, _ handler: @escaping @Sendable (HostEvent) -> Void
    ) -> any HostConnectionHandle {
        let number = count.withLock { count in
            count += 1
            return count
        }
        let events = events
        policies.record((number, policy))
        let connection: HostConnection = runtime.makeConnection(
            stream, policy: policy, bundles: bundles, deliveringOn: queue
        ) { event in
            events.record((number, event))
            handler(event)
        }
        return Recorded(connection: connection, number: number, commands: commands)
    }

    /// Every `.closed` each connection reported, by connection number.
    var closures: [Int: Int] {
        events.elements.reduce(into: [:]) { counts, entry in
            if case .closed = entry.event { counts[entry.connection, default: 0] += 1 }
        }
    }

    private struct Recorded: HostConnectionHandle {
        let connection: HostConnection
        let number: Int
        let commands: Recorder<(connection: Int, command: HostCommand)>

        var generation: ConnectionGeneration { connection.generation }

        func start() { connection.start() }

        func send(_ command: HostCommand) {
            commands.record((number, command))
            connection.send(command)
        }
    }
}

/// A transport the test opens connections through: it keeps each acceptor the hub starts it with.
final class TestTransport: GuestStreamTransport {
    private let acceptors = Locked<[GuestStreamAcceptor]>([])
    /// How many times the hub stopped it.
    let stops = Locked(0)

    func start(admitting acceptor: GuestStreamAcceptor) {
        acceptors.withLock { $0.append(acceptor) }
    }

    func stop() {
        stops.withLock { $0 += 1 }
    }

    /// The acceptor the hub last started it with.
    var acceptor: GuestStreamAcceptor? { acceptors.withLock(\.last) }

    /// Opens a connection through the acceptor, answering its peer end, or `nil` when refused.
    func connect() -> MemoryStream? {
        let (host, peer) = MemoryStream.pair()
        let accepted =
            acceptor?.offer { released in
                host.onRelease(released)
                return host
            } ?? false
        return accepted ? peer : nil
    }
}

/// A hub with its transport attached, joined to its peers by in-memory streams, on the platform clock.
final class HubHarness: Sendable {
    let connector: RecordingConnector
    let hub: AgentHub
    let transport = TestTransport()
    let snapshots = Recorder<AgentHubSnapshot>()
    /// What the republisher logged: level, and each segment.
    let guestLogs = Recorder<(level: KernovaLogLevel, segments: [LogSegment])>()
    /// The hub's own notices: its acceptor's.
    let hostLogs = Recorder<String>()
    private let publishQueue = DispatchQueue(label: "app.kernova.tests.hub-publish")

    /// A hub attached to `transport`, its peers judged by `receiverPolicy`.
    init(
        policy: PolicySnapshot = PolicySnapshot(), bundles: [BundledPayload] = [],
        receiverPolicy: ReceiverPolicy = .production
    ) {
        connector = RecordingConnector(receiverPolicy: receiverPolicy)
        let (snapshots, hostLogs) = (snapshots, hostLogs)
        hub = AgentHub(
            connector: connector, policy: policy, payloads: FixedPayloads(bundles: bundles),
            logger: KernovaLogger(subsystem: "app.kernova", category: "AgentHub") { _, _, _, segments in
                hostLogs.record(segments.map(\.text).joined())
            },
            publishingOn: publishQueue
        ) { snapshots.record($0) }
        hub.attach(transport, policy: policy, republisher: republisher)
    }

    /// Waits until the transport is accepting.
    func attached() async {
        await flush(hub.queue)
    }

    /// The republisher the harness attaches with, recording into `guestLogs`.
    var republisher: GuestLogRepublisher {
        let guestLogs = guestLogs
        return GuestLogRepublisher(
            logger: KernovaLogger(subsystem: "app.kernova.guest", category: "VM") { level, _, _, segments in
                guestLogs.record((level, segments))
            })
    }

    /// The next snapshot `predicate` accepts, from the first.
    func snapshot(where predicate: (AgentHubSnapshot) -> Bool) async -> AgentHubSnapshot {
        var waiter = snapshots.waiter()
        return await waiter.next(where: predicate)
    }

    /// Opens a connection through the transport, answering its peer end, or `nil` when refused.
    func connect() -> MemoryStream? {
        transport.connect()
    }

    /// A `PeerAgentRuntime` dialing this hub's transport.
    func runtime(
        claim: PeerClaim = Fixture.peerClaim, state: PeerSessionState = Fixture.peerState,
        registry: PeerFeatureRegistry = PeerFeatureRegistry(), events: Recorder<PeerEvent> = Recorder()
    ) -> PeerAgentRuntime {
        PeerAgentRuntime(
            claim: claim, state: state, registry: registry, dialer: HubDialer(harness: self),
            scheduler: SystemScheduler(), logger: Fixture.logger,
            handlers: PeerAgentRuntime.Handlers(event: { events.record($0) }, stop: { _ in }))
    }
}

/// Dials a hub harness's transport.
struct HubDialer: TransportDialer {
    let harness: HubHarness

    func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void) {
        guard let stream = harness.connect() else { return completion(.failure(.transient)) }
        completion(.success(stream))
    }
}

/// A peer endpoint with the claim the test gives it, driven over one connection to a hub harness.
final class HubPeer: Sendable {
    let stream: MemoryStream
    let driver: ConnectionDriver<PeerEndpoint>
    let events = Recorder<PeerEvent>()

    convenience init(_ harness: HubHarness, claim: PeerClaim, state: PeerSessionState = Fixture.peerState) {
        self.init(harness.transport, claim: claim, state: state)
    }

    init(_ transport: TestTransport, claim: PeerClaim, state: PeerSessionState = Fixture.peerState) {
        guard let stream = transport.connect() else { preconditionFailure("the transport refused a connection") }
        self.stream = stream
        let events = events
        let scheduler = SystemScheduler()
        driver = ConnectionDriver(
            endpoint: PeerEndpoint(
                PeerConfiguration(
                    claim: claim, state: state, power: .absent(.notImplemented, debugDetail: ""),
                    logs: .absent(.notImplemented, debugDetail: ""), update: .absent(.notImplemented, debugDetail: "")),
                generation: ConnectionGeneration(rawValue: 1), now: scheduler.now),
            stream: stream, scheduler: scheduler, logger: Fixture.logger,
            handlers: ConnectionDriver<PeerEndpoint>.Handlers(event: { event, _ in events.record(event) }))
        driver.start()
    }

    /// How the connection ended, once it has.
    func closure() async -> ConnectionClosure {
        var waiter = events.waiter()
        guard case .closed(let closure) = await waiter.next(where: { if case .closed = $0 { true } else { false } })
        else { preconditionFailure() }
        return closure
    }
}

extension PeerClaim {
    /// A session peer of `scope` in process `instance`.
    static func session(_ scope: InstallScope, instance: UInt8) -> PeerClaim {
        PeerClaim(
            role: .sessionPeer, scope: scope, os: .linux, architecture: .arm64, versionLabel: "peer",
            instanceID: Data(repeating: instance, count: 16))
    }
}
