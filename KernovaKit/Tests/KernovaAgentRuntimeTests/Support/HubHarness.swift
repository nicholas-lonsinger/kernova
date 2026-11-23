#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaLogging
import KernovaPortableTestSupport
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

/// Serves every payload as zero bytes, up to its size.
struct ZeroPayloads: UpdatePayloadSource {
    func read(
        manifest: UpdateManifestValue, offset: UInt64, count: Int,
        _ completion: @escaping @Sendable (Result<Data, WireError>) -> Void
    ) {
        completion(.success(Data(count: min(count, Int(manifest.payloadSize - offset)))))
    }
}

/// The real host runtime, with every connection's commands and events recorded by connection number,
/// from 1 in accept order.
final class RecordingConnector: HostConnectionMaking {
    let runtime: HostConnectionRuntime
    let commands = Recorder<(connection: Int, command: HostCommand)>()
    let events = Recorder<(connection: Int, event: HostEvent)>()
    private let count = Locked(0)

    init(payloadSource: any UpdatePayloadSource, items: ItemAdapters?) {
        runtime = HostConnectionRuntime(
            claim: Fixture.hostClaim, scheduler: SystemScheduler(), payloadSource: payloadSource, items: items,
            logger: Fixture.logger)
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
        let connection: HostConnection = runtime.makeConnection(
            stream, policy: policy, bundles: bundles, deliveringOn: queue
        ) { event in
            events.record((number, event))
            handler(event)
        }
        return Recorded(connection: connection, number: number, commands: commands)
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

    func start(admitting acceptor: GuestStreamAcceptor) {
        acceptors.withLock { $0.append(acceptor) }
    }

    func stop() {}

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
    /// The hub's item events, and what each test records beside them on the hub's queue.
    let itemLog = Recorder<ItemLogEntry>()
    /// What the republisher logged: level, and each segment.
    let guestLogs = Recorder<(level: KernovaLogLevel, segments: [LogSegment])>()
    /// Where the hub delivers its snapshots.
    let publishQueue = DispatchQueue(label: "app.kernova.tests.hub-publish")

    /// A hub attached to `transport`, its peers' pulls read from `payloadSource`, and its items served by
    /// `items`; each item event reaches `itemEvents` once logged.
    init(
        policy: PolicySnapshot = PolicySnapshot(), bundles: [BundledPayload] = [],
        payloadSource: any UpdatePayloadSource = FixedPayloads(bundles: []), items: ItemAdapters? = nil,
        itemEvents: @escaping @Sendable (HubItemEvent) -> Void = { _ in }
    ) {
        connector = RecordingConnector(payloadSource: payloadSource, items: items)
        let (snapshots, itemLog) = (snapshots, itemLog)
        hub = AgentHub(
            connector: connector, policy: policy, payloads: FixedPayloads(bundles: bundles), logger: Fixture.logger,
            itemEvents: { event in
                itemLog.record(.event(event))
                itemEvents(event)
            },
            publishingOn: publishQueue
        ) { snapshots.record($0) }
        hub.attach(transport, policy: policy, republisher: republisher)
    }

    /// Waits until the transport is accepting.
    func attached(fileID: String = #fileID, line: Int = #line) async throws {
        try await flush(hub.queue, fileID: fileID, line: line)
    }

    /// The republisher the harness attaches with, recording into `guestLogs`.
    var republisher: GuestLogRepublisher {
        let guestLogs = guestLogs
        return GuestLogRepublisher(
            logger: KernovaLogger(
                subsystem: "app.kernova.guest", category: "VM",
                sink: .init { level, _, _, segments in
                    guestLogs.record((level, segments))
                }))
    }

    /// Waits until every event the hub has received is reflected in `snapshots`.
    func settled(fileID: String = #fileID, line: Int = #line) async throws {
        try await flush(hub.queue, fileID: fileID, line: line)
        try await flush(publishQueue, fileID: fileID, line: line)
    }

    /// The next snapshot `predicate` accepts, from the first.
    func snapshot(
        fileID: String = #fileID, line: Int = #line, where predicate: (AgentHubSnapshot) -> Bool
    ) async throws -> AgentHubSnapshot {
        var waiter = snapshots.waiter()
        return try await waiter.next(fileID: fileID, line: line, where: predicate)
    }

    /// Opens a connection through the transport, answering its peer end, or `nil` when refused.
    func connect() -> MemoryStream? {
        transport.connect()
    }

    /// The hub's answer to a power request, once it has one: the request waits for its peer's report.
    func requestPower(
        _ action: PowerAction, ignoringApps: Bool = false, fileID: String = #fileID, line: Int = #line
    ) async throws -> PowerRoutingOutcome {
        let hub = hub
        return try await Backstop("AgentHub.requestPower", fileID: fileID, line: line).run {
            await hub.requestPower(action, ignoringApps: ignoringApps)
        }
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

    convenience init(
        _ harness: HubHarness, claim: PeerClaim, state: PeerSessionState = Fixture.peerState,
        update: Availability<UpdateOffer> = .absent(.notImplemented, debugDetail: ""), refuses: ErrorCode? = nil,
        items: MemoryItems? = nil
    ) {
        self.init(harness.transport, claim: claim, state: state, update: update, refuses: refuses, items: items)
    }

    /// A peer whose installer is `update`: with `refuses`, it reports every pull's bytes consumed and the
    /// payload rejected with that code; otherwise it never answers. With `items`, it serves every item feature
    /// through them.
    init(
        _ transport: TestTransport, claim: PeerClaim, state: PeerSessionState = Fixture.peerState,
        update: Availability<UpdateOffer> = .absent(.notImplemented, debugDetail: ""), refuses: ErrorCode? = nil,
        items: MemoryItems? = nil
    ) {
        guard let stream = transport.connect() else { preconditionFailure("the transport refused a connection") }
        self.stream = stream
        let events = events
        let scheduler = SystemScheduler()
        var configuration = PeerConfiguration(
            claim: claim, state: state, power: .absent(.notImplemented, debugDetail: ""),
            logs: .absent(.notImplemented, debugDetail: ""), update: update)
        if items != nil { configuration.items = SimItems.served }
        driver = ConnectionDriver(
            endpoint: PeerEndpoint(configuration, generation: ConnectionGeneration(rawValue: 1), now: scheduler.now),
            stream: stream, scheduler: scheduler, logger: Fixture.logger,
            handlers: ConnectionDriver<PeerEndpoint>.Handlers(
                effect: { effect, driver in
                    switch effect {
                    case .role(.update(.payload(let id, let bytes))) where refuses != nil:
                        driver.handle(.update(.consumed(id, bytes.count)))
                    case .role(.update(.complete(let id, _))):
                        if let refuses { driver.handle(.update(.rejected(id, WireError(refuses)))) }
                    case .itemSource(let effect):
                        if let input = items?.serve(effect) { driver.handle(.items(.source(input))) }
                    case .itemSink(let effect):
                        if let input = items?.land(effect) { driver.handle(.items(.sink(input))) }
                    default:
                        break
                    }
                },
                event: { event, _ in events.record(event) }))
        driver.start()
    }

    /// Feeds the endpoint `command`.
    func send(_ command: ItemCommand) {
        driver.handle(.itemCommand(command))
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

/// One entry of a hub harness's item log: an item event the hub handed on, or a note a test made on the
/// hub's queue, such as a call's answer.
enum ItemLogEntry: Sendable, Equatable {
    case event(HubItemEvent)
    case note(String)
}
