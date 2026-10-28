#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a host endpoint is created with (§9.3).
public struct HostConfiguration: Sendable {
    /// The host's claim: role HOST, Kernova's version label.
    public var claim: PeerClaim
    /// The 16 random bytes the runtime drew for this connection.
    public var sessionToken: Data
    /// The VM's policy for policy-governed features.
    public var policy: PolicySnapshot
    /// The payloads the host bundles.
    public var bundles: [BundledPayload]
    /// The receiver policy the peer is judged by.
    public var receiverPolicy: ReceiverPolicy = .production
    package var tweak: @Sendable (inout ConnectionConfiguration) -> Void = { _ in }

    /// Creates a configuration.
    public init(claim: PeerClaim, sessionToken: Data, policy: PolicySnapshot, bundles: [BundledPayload]) {
        self.claim = claim
        self.sessionToken = sessionToken
        self.policy = policy
        self.bundles = bundles
    }
}

/// What the hub tells one host endpoint; ids are the hub's.
public enum HostCommand: Sendable, Equatable {
    /// The VM was live-paused (`true`) or resumed.
    case setPeerFrozen(Bool)
    /// Ask the peer to perform `action`.
    case requestPower(PowerRequestID, PowerAction)
    /// Cancel a request still waiting for acceptance.
    case cancelPower(PowerRequestID)
    /// The VM's policy changed.
    case setPolicy(PolicySnapshot)
    /// The bundled payloads changed; re-sends `UpdateAvailable` and resets a pull it makes stale.
    case setBundles([BundledPayload])
    /// Payload bytes for the outstanding read: 1 … `maxBytes` of them, from its offset.
    case updateBytes(UpdatePullID, Data)
    /// The payload source failed.
    case updateFailed(UpdatePullID, WireError)
    /// Close the connection (`SUPERSEDED`, `DUPLICATE_PEER`, `SHUTTING_DOWN`).
    case close(ErrorCode, retryAfter: CoreDuration?)
}

/// What a host endpoint tells the hub.
public enum HostEvent: Sendable, Equatable {
    /// The peer's Hello was read.
    case helloReceived(PeerClaim, PeerSessionState)
    /// The peer's state changed (coalesced, §4.4).
    case peerStateChanged(PeerSessionState)
    /// Some feature's usability changed (§4.3; coalesced, §4.4).
    case featuresChanged(FeatureStatusTable)
    /// A liveness verdict about the peer.
    case liveness(LivenessChange)
    /// A power request's progress or result.
    case power(PowerRequestID, PowerRequestResult)
    /// Forwarded guest log records.
    case log(LogDelivery)
    /// An update pull's progress.
    case update(UpdateServeEvent)
    /// A note for the runtime's log.
    case diagnostic(Diagnostic)
    /// The connection ended.
    case closed(ConnectionClosure)
}

/// One accepted connection's whole state, owned by its driver.
public struct HostEndpoint: Sendable {
    package private(set) var connection: Connection
    private var power: PowerRequester
    private var logs = LogReceiver()
    private var update: UpdateServer
    package var testSink = TestBulkSink()
    /// The connection this endpoint runs.
    public let generation: ConnectionGeneration
    private var events = OutputQueue<HostEvent, HostEventSlot>()
    private var lastStatus: FeatureStatusTable?

    /// Creates the endpoint of a connection just accepted.
    public init(_ configuration: HostConfiguration, generation: ConnectionGeneration, now: CoreInstant) {
        self.generation = generation
        power = PowerRequester(generation: generation)
        update = UpdateServer(generation: generation)
        var connectionConfiguration = ConnectionConfiguration(
            claim: configuration.claim, adverts: [], sessionToken: configuration.sessionToken,
            hostPolicy: configuration.policy, hostBundles: configuration.bundles, policy: configuration.receiverPolicy)
        connectionConfiguration.adverts = [
            (.power, power.localAdvert), (.update, update.localAdvert), (.logs, logs.localAdvert),
        ]
        configuration.tweak(&connectionConfiguration)
        connection = Connection(connectionConfiguration, now: now)
    }

    /// The connection's phase.
    public var state: ConnectionState { connection.state }

    /// When the driver must next call `handleTimeout`: the soonest of the
    /// connection's deadline and every machine's, each computed from the clock now.
    public var nextDeadline: CoreInstant? {
        guard connection.state != .finished else { return nil }
        let clock = connection.clock
        let machines = [power.nextDeadline(on: clock), logs.nextDeadline(on: clock), update.nextDeadline(on: clock)]
        return [connection.nextDeadline, clock.external(machines.compactMap { $0 }.min())].compactMap { $0 }.min()
    }

    // MARK: Inputs

    /// Bytes from the transport.
    public mutating func receive(_ bytes: Data, now: CoreInstant) {
        connection.ingest(bytes, now: now)
        route(now)
        while connection.processNextFrame() {
            route(now)
        }
        connection.finishReceive()
        route(now)
    }

    /// The transport ended.
    public mutating func transportEnded(now: CoreInstant) {
        connection.transportEnded(now: now)
        route(now)
    }

    /// The timer fired.
    public mutating func handleTimeout(now: CoreInstant) {
        connection.handleTimeout(now: now)
        route(now)
        notifyAll(.deadline, now)
        route(now)
    }

    /// A hub command.
    public mutating func handle(_ command: HostCommand, now: CoreInstant) {
        connection.tick(now)
        route(now)
        switch command {
        case .setPeerFrozen(let frozen):
            connection.setPeerFrozen(frozen, now: now)
        case .requestPower(let id, let action):
            power.request(id, action, connection: &connection)
        case .cancelPower(let id):
            power.cancel(id, connection: &connection)
        case .setPolicy(let policy):
            connection.setPolicy(policy)
            notifyAll(.policyChanged, now)
            notifyAll(.usabilityChanged, now)
            refreshStatus()
        case .setBundles(let bundles):
            connection.setBundles(bundles)
            update.offerChanged(connection.offeredUpdate, connection: &connection)
        case .updateBytes(let id, let data):
            if id.generation == generation { update.bytes(id, data, connection: &connection) }
        case .updateFailed(let id, let error):
            if id.generation == generation { update.failed(id, error, connection: &connection) }
        case .close(let code, let retryAfter):
            connection.close(code, retryAfter: retryAfter, now: now)
        }
        route(now)
    }

    /// Opens a bulk test stream (§10.4).
    package mutating func openTestBulk(_ kind: StreamKind, consumes: Bool, now: CoreInstant) -> StreamID? {
        connection.tick(now)
        route(now)
        let stream = testSink.open(kind, consumes: consumes, connection: &connection)
        route(now)
        return stream
    }

    package mutating func setTestConsumes(_ consumes: Bool, on stream: StreamID, now: CoreInstant) {
        connection.tick(now)
        testSink.setConsumes(consumes, on: stream, connection: &connection)
        route(now)
    }

    // MARK: Outputs

    /// The next frames to write.
    public mutating func pollTransmit(maxBytes: Int) -> Transmit? {
        let transmit = connection.pollTransmit(maxBytes: maxBytes)
        route(connection.clock.raw)
        return transmit
    }

    /// The next event for the hub.
    public mutating func pollEvent() -> HostEvent? {
        events.poll()
    }

    package mutating func takeTrace() -> [ConnectionTrace] {
        connection.takeTrace()
    }

    // MARK: Routing

    private mutating func route(_ now: CoreInstant) {
        while true {
            collect()
            guard let routed = connection.pollRoutedEvent() else { break }
            dispatch(routed, now)
        }
    }

    private mutating func notifyAll(_ event: FeatureEvent, _ now: CoreInstant) {
        power.handle(event, connection: &connection, now: now)
        logs.handle(event, connection: &connection, now: now)
        update.handle(event, connection: &connection, now: now)
    }

    private mutating func refreshStatus() {
        guard connection.remoteHello != nil else { return }
        let status = connection.featureStatus
        guard status != lastStatus else { return }
        lastStatus = status
        events.append(.featuresChanged(status), coalescing: .features)
    }

    private mutating func dispatch(_ routed: RoutedEvent, _ now: CoreInstant) {
        switch routed.event {
        case .helloReceived(let hello):
            events.append(.helloReceived(hello.claim, hello.state ?? PeerSessionState()))
            notifyAll(.sessionEstablished, now)
            refreshStatus()
        case .remoteAdvertsChanged:
            notifyAll(.usabilityChanged, now)
            refreshStatus()
        case .peerStateChanged(let state):
            events.append(.peerStateChanged(state), coalescing: .peerState)
        case .policyChanged, .updateAvailable:
            break
        case .liveness(let change):
            events.append(.liveness(change))
        case .diagnostic(let diagnostic):
            events.append(.diagnostic(diagnostic))
        case .closed(let closure):
            events.append(.closed(closure))
        case .opened(let id, _, let body):
            deliver(.opened(id, body: body), to: routed.owner, now)
        case .message(let id, let payload):
            deliver(.message(id, payload), to: routed.owner, now)
        case .data(let id, let payload):
            deliver(.data(id, payload), to: routed.owner, now)
        case .remoteEnded(let id, let body):
            deliver(.remoteEnded(id, body: body), to: routed.owner, now)
        case .writable(let id):
            deliver(.writable(id), to: routed.owner, now)
        case .streamClosed(let id, let closure):
            deliver(.streamClosed(id, closure), to: routed.owner, now)
        }
    }

    private mutating func deliver(_ event: FeatureEvent, to owner: KindOwner?, _ now: CoreInstant) {
        switch owner {
        case .power: power.handle(event, connection: &connection, now: now)
        case .update: update.handle(event, connection: &connection, now: now)
        case .logs: logs.handle(event, connection: &connection, now: now)
        case .testBulk: testSink.handle(event, connection: &connection)
        case nil: break
        }
    }

    private mutating func collect() {
        for output in [power.takeOutputs(), logs.takeOutputs(), update.takeOutputs()] {
            for event in output.events { events.append(event) }
            for diagnostic in output.diagnostics {
                connection.diagnose(diagnostic)
            }
        }
    }
}

/// The host's events that coalesce (§4.4).
enum HostEventSlot: Hashable, Sendable {
    case peerState, features
}
