#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// The update payloads a host bundles for its guests, and their bytes: what it offers is what it can
/// serve.
public protocol BundledPayloadProvider: UpdatePayloadSource {
    /// Calls `completion` once, on any thread, with the payloads to offer. It may compute them first, so
    /// it runs off the caller's thread.
    func loadPayloads(_ completion: @escaping @Sendable ([BundledPayload]) -> Void)
}

/// What a host connection is built with, as of now: read at accept, so a connection's Hello is
/// answered from the configuration current when it was accepted (spec §4.1.5).
struct HostConfigurationTemplate: Sendable {
    var policy: PolicySnapshot
    var bundles: [BundledPayload] = []
}

/// Builds the hub's host connections: `HostConnectionRuntime` in a shipping build.
public protocol HostConnectionMaking: Sendable {
    /// A connection over `stream`, not yet started, whose events reach `handler` on `queue`.
    func makeConnection(
        _ stream: any ByteStream, policy: PolicySnapshot, bundles: [BundledPayload],
        deliveringOn queue: DispatchQueue, _ handler: @escaping @Sendable (HostEvent) -> Void
    ) -> any HostConnectionHandle
}

/// One host connection, as the hub drives it.
public protocol HostConnectionHandle: Sendable {
    /// The connection's generation, which every power request id the hub sends it carries.
    var generation: ConnectionGeneration { get }
    /// Starts the connection.
    func start()
    /// Sends `command` to the connection's driver with `async`.
    func send(_ command: HostCommand)
}

extension HostConnectionRuntime: HostConnectionMaking {
    /// A connection over `stream`, as ``HostConnectionRuntime/makeConnection(_:policy:bundles:deliveringOn:_:)``
    /// builds it.
    public func makeConnection(
        _ stream: any ByteStream, policy: PolicySnapshot, bundles: [BundledPayload],
        deliveringOn queue: DispatchQueue, _ handler: @escaping @Sendable (HostEvent) -> Void
    ) -> any HostConnectionHandle {
        let connection: HostConnection = makeConnection(
            stream, policy: policy, bundles: bundles, deliveringOn: queue, handler)
        return connection
    }
}

extension HostConnection: HostConnectionHandle {}

/// One VM's guest agents: the connections its transport accepts, the peer set they form, and the one
/// status the main actor reads.
///
/// The state lives on the hub's own serial queue. Every method returns at once, posting its work there;
/// drivers deliver events there and take commands from it, both with `async`, so no queue ever waits on
/// another (spec §9.7). Snapshots reach `publish` on the publishing queue, coalesced: at most one is
/// pending, and a newer one replaces it.
public final class AgentHub: Sendable {
    /// The hub's queue: serial, every input to its state runs on it.
    package let queue = DispatchQueue(label: "app.kernova.agent-hub")
    private let connector: any HostConnectionMaking
    private let template: Locked<HostConfigurationTemplate>
    private let handles = Locked<UInt64>(0)
    private let state = Locked(AgentHubState())
    private let publisher: SnapshotPublisher
    private let logger: KernovaLogger

    /// A hub whose connections say Hello as `claim`, offer `payloads`' bundles and serve their bytes,
    /// and start with `policy`.
    public convenience init(
        claim: PeerClaim, policy: PolicySnapshot, payloads: any BundledPayloadProvider,
        scheduler: any RuntimeScheduler = SystemScheduler(),
        logger: KernovaLogger = KernovaLogger(subsystem: "app.kernova", category: "AgentHub"),
        publishingOn publishQueue: DispatchQueue = .main,
        _ publish: @escaping @Sendable (AgentHubSnapshot) -> Void
    ) {
        self.init(
            connector: HostConnectionRuntime(
                claim: claim, scheduler: scheduler, payloadSource: payloads, logger: logger),
            policy: policy, payloads: payloads, logger: logger, publishingOn: publishQueue, publish)
    }

    /// A hub whose connections `connector` builds.
    public init(
        connector: any HostConnectionMaking, policy: PolicySnapshot, payloads: any BundledPayloadProvider,
        logger: KernovaLogger, publishingOn publishQueue: DispatchQueue,
        _ publish: @escaping @Sendable (AgentHubSnapshot) -> Void
    ) {
        self.connector = connector
        self.logger = logger
        template = Locked(HostConfigurationTemplate(policy: policy))
        publisher = SnapshotPublisher(queue: publishQueue, deliver: publish)
        payloads.loadPayloads { [self] bundles in setBundles(bundles) }
    }

    // MARK: Lifecycle

    /// Starts accepting through `transport` with `policy` current, admitting at most
    /// `GuestStreamAcceptor.connectionLimit` connections at once and republishing guest logs through
    /// `republisher`; a transport attached before is detached first. Once the hub is closed, does nothing.
    public func attach(
        _ transport: any GuestStreamTransport, policy: PolicySnapshot, republisher: GuestLogRepublisher
    ) {
        setPolicy(policy)
        queue.async { [self] in
            let acceptor = GuestStreamAcceptor(logger: logger) { [self] stream in accept(stream) }
            let attached = state.withLock { state -> Bool in
                guard !state.isClosed else { return false }
                state.republisher = republisher
                return true
            }
            guard attached else { return }
            detachTransport()
            state.withLock { $0.attachment = (transport, acceptor) }
            transport.start(admitting: acceptor)
        }
    }

    /// Stops the attached transport and shuts down every stream it accepted, so each connection ends as
    /// its transport does.
    public func detach() {
        queue.async { [self] in detachTransport() }
    }

    /// Tells every connection the guest is frozen (the VM is live-paused) or running again, so its
    /// silence is not judged while it cannot run.
    public func setGuestFrozen(_ frozen: Bool) {
        queue.async { [self] in
            broadcast(.setPeerFrozen(frozen)) { $0.isFrozen = frozen }
        }
    }

    /// Sends `policy` to every connection, and builds later ones with it.
    public func setPolicy(_ policy: PolicySnapshot) {
        // The template and the broadcast change together under the template's lock, as the accept path
        // reads it and posts its registration: a connection is either built with the new policy or
        // registered before the broadcast reaches the queue.
        template.withLock { template in
            template.policy = policy
            queue.async { [self] in broadcast(.setPolicy(policy)) { _ in } }
        }
    }

    /// Detaches the transport and refuses every later attach.
    public func close() {
        queue.async { [self] in
            state.withLock { $0.isClosed = true }
            detachTransport()
        }
    }

    // MARK: Power

    /// Routes `action` across the peers (spec §6.4) — the console session's peers newest first, then the
    /// system peer — and calls `completion` once, on the hub's queue, with how it ended. The hub never
    /// presses the ACPI button: `.useACPI` hands that back to the caller.
    public func requestPower(_ action: PowerAction, _ completion: @escaping @Sendable (PowerRoutingOutcome) -> Void) {
        queue.async { [self] in
            let begun = state.withLock { state -> Bool in
                guard !state.power.routing.isRouting else { return false }
                state.power.completion = completion
                state.power.routing.begin(action, peers: state.routingPeers)
                return true
            }
            guard begun else { return completion(.busy) }
            logger.log(.notice, "Routing \(Self.name(action), privacy: .public) across the guest's agents")
            drainRouting()
        }
    }

    /// ``requestPower(_:_:)``, awaited.
    public func requestPower(_ action: PowerAction) async -> PowerRoutingOutcome {
        await withCheckedContinuation { continuation in
            requestPower(action) { continuation.resume(returning: $0) }
        }
    }

    /// Carries out the routing's outputs: each ask becomes a request to that peer's connection, each
    /// progress the snapshot's stage, and the terminal output the caller's outcome.
    private func drainRouting() {
        dispatchPrecondition(condition: .onQueue(queue))
        while let output = state.withLock({ $0.power.routing.pollOutput() }) {
            switch output {
            case .ask(let handle, let action):
                ask(handle, action)
            case .progress(_, let stage, let apps):
                state.withLock { state in
                    state.power.progress?.stage =
                        switch stage {
                        case .askingApps: .askingApps
                        case .waitingOnApps: .waitingOnApps(apps)
                        }
                }
            default:
                guard let outcome = PowerRoutingOutcome(output) else { continue }
                let completion = state.withLock { state in
                    defer {
                        state.power.completion = nil
                        state.power.progress = nil
                    }
                    return state.power.completion
                }
                logger.log(.notice, "Power routing ended: \(String(describing: outcome), privacy: .public)")
                completion?(outcome)
            }
        }
        publishIfChanged()
    }

    private func ask(_ handle: PeerHandle, _ action: PowerAction) {
        // `PowerRouting` asks only a peer of `routingPeers`, read on this queue in the same turn, and a
        // peer and its connection leave the hub together; so both are present.
        let (connection, id, record) = state.withLock { state in
            let connection = state.connections[handle]!
            let record = state.peers[handle]!
            let id = state.power.drawID(connection.generation)
            state.power.requests[id] = handle
            state.power.progress = PowerRoutingProgress(action: action, role: record.claim.role, stage: .asking)
            return (connection, id, record)
        }
        logger.log(
            .notice, "Asking the \(Self.name(record), privacy: .public) to \(Self.name(action), privacy: .public)")
        connection.send(.requestPower(id, action))
    }

    /// A power request's result, from the connection it was asked of.
    private func powerResult(_ id: PowerRequestID, _ result: PowerRequestResult) {
        state.withLock { state in
            guard let handle = state.power.requests[id] else { return }
            switch result {
            case .accepted:
                state.power.progress?.stage = .accepted
            case .progress:
                break
            case .refused, .indeterminate, .finished, .lostAfterAcceptance:
                state.power.requests[id] = nil
            }
            state.power.routing.handle(result, from: handle, peers: state.routingPeers)
        }
        drainRouting()
    }

    /// The connection `handle` ended. A request asked of it that never reached its endpoint — the driver
    /// drops what is sent after it shut down — reported nothing, and nothing was done.
    private func endRequests(of handle: PeerHandle) {
        let unanswered = state.withLock { state in
            state.power.requests.filter { $0.value == handle }.map(\.key)
        }
        for id in unanswered {
            powerResult(
                id,
                .refused(WireError(.shuttingDown, debugDetail: "the connection ended before the request reached it")))
        }
    }

    private static func name(_ action: PowerAction) -> String {
        switch action {
        case .shutdown: "shut down"
        case .restart: "restart"
        case .unspecified, .UNRECOGNIZED: "act on \(action)"
        }
    }

    private static func name(_ record: PeerRecord) -> String {
        switch record.claim.role {
        case .systemPeer: "system peer"
        case .sessionPeer, .host:
            "session peer (session \(record.state.sessionID), user \(record.state.userName))"
        }
    }

    private func detachTransport() {
        dispatchPrecondition(condition: .onQueue(queue))
        let attachment = state.withLock { state in
            defer { state.attachment = nil }
            return state.attachment
        }
        guard let attachment else { return }
        // The listener first, so nothing more is offered while the acceptor shuts the live streams.
        attachment.transport.stop()
        attachment.acceptor.stop()
    }

    // MARK: Connections

    private func setBundles(_ bundles: [BundledPayload]) {
        template.withLock { template in
            template.bundles = bundles
            queue.async { [self] in
                broadcast(.setBundles(bundles)) { $0.bundles = bundles }
                publishIfChanged()
            }
        }
    }

    /// The transport's accept path, on the thread that accepted: builds the connection from the template
    /// and registers it on the hub's queue before starting it, so the registration runs before any of
    /// its events.
    private func accept(_ stream: any ByteStream) {
        let handle = PeerHandle(
            rawValue: handles.withLock { count in
                count += 1
                return count
            })
        let connection = template.withLock { template in
            let connection = connector.makeConnection(
                stream, policy: template.policy, bundles: template.bundles, deliveringOn: queue
            ) { [self] event in receive(event, from: handle) }
            queue.async { [self] in register(handle, connection) }
            return connection
        }
        connection.start()
    }

    private func register(_ handle: PeerHandle, _ connection: any HostConnectionHandle) {
        let frozen = state.withLock { state in
            state.connections[handle] = connection
            return state.isFrozen
        }
        if frozen { connection.send(.setPeerFrozen(true)) }
    }

    /// Updates the state with `update` and sends `command` to every connection, in one step on the queue.
    private func broadcast(_ command: HostCommand, _ update: (inout AgentHubState) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let connections = state.withLock { state in
            update(&state)
            return Array(state.connections.values)
        }
        for connection in connections { connection.send(command) }
    }

    private func receive(_ event: HostEvent, from handle: PeerHandle) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch event {
        case .helloReceived(let claim, let peerState):
            let outcome = state.withLock { $0.helloReceived(handle, claim: claim, state: peerState) }
            resolve(outcome, incoming: handle)
        case .peerStateChanged(let peerState):
            state.withLock { $0.peers[handle]?.state = peerState }
        case .featuresChanged(let table):
            state.withLock { $0.peers[handle]?.features = table }
        case .liveness(let change):
            state.withLock { $0.peers[handle]?.isResponsive = change == .responsive }
        case .closed:
            state.withLock { $0.closed(handle) }
            endRequests(of: handle)
        case .log(let delivery):
            // Records change no peer state, so the snapshot is not rebuilt.
            return republish(delivery, from: handle)
        case .power(let id, let result):
            return powerResult(id, result)
        case .update, .diagnostic:
            // Nothing serves a pull's progress yet, and the driver logs diagnostics itself.
            return
        }
        publishIfChanged()
    }

    private func resolve(_ outcome: HelloOutcome?, incoming: PeerHandle) {
        let loser: (PeerHandle, ErrorCode, CoreDuration?)? =
            switch outcome {
            case .displaced(let existing, let code, let retryAfter): (existing, code, retryAfter)
            case .refused(let code, let retryAfter): (incoming, code, retryAfter)
            case .joined, nil: nil
            }
        guard let (handle, code, retryAfter) = loser else { return }
        state.withLock { $0.connections[handle] }?.send(.close(code, retryAfter: retryAfter))
    }

    /// Republishes `delivery` behind its peer's source, `session <id>` or `system` (spec §7.4), a drop
    /// report included, so everything a guest's ring sends stays in the guest namespace under its VM.
    private func republish(_ delivery: LogDelivery, from handle: PeerHandle) {
        let (peer, republisher) = state.withLock { ($0.peers[handle], $0.republisher) }
        guard let peer, let republisher else { return }
        let source = peer.claim.role == .systemPeer ? "system" : "session \(peer.state.sessionID)"
        switch delivery {
        case .records(let records):
            for record in records {
                republisher.republish(
                    KernovaLogLevel(record.level), prefix: "[\(source) \(record.subsystem)/\(record.category)] ",
                    record.segments.map { LogSegment(text: $0.text, isPrivate: $0.isPrivate) })
            }
        case .dropped(let count):
            republisher.republish(
                .notice, prefix: "[\(source)] ",
                [LogSegment(text: "Dropped \(count) log record(s) while the host was behind", isPrivate: false)])
        }
    }

    private func publishIfChanged() {
        let snapshot = state.withLock { state -> AgentHubSnapshot? in
            let snapshot = state.snapshot
            guard snapshot != state.lastPublished else { return nil }
            state.lastPublished = snapshot
            return snapshot
        }
        if let snapshot { publisher.publish(snapshot) }
    }
}

extension KernovaLogLevel {
    /// A forwarded record's level, one to one; `UNSPECIFIED` is a notice.
    init(_ level: LogLevelValue) {
        switch level {
        case .unspecified, .notice: self = .notice
        case .debug: self = .debug
        case .info: self = .info
        case .warning: self = .warning
        case .error: self = .error
        case .fault: self = .fault
        }
    }
}

/// Hands snapshots to the publishing queue, at most one pending: a newer one replaces it.
private final class SnapshotPublisher: Sendable {
    private struct Pending: Sendable {
        var latest: AgentHubSnapshot?
        var isScheduled = false
    }

    private let queue: DispatchQueue
    private let deliver: @Sendable (AgentHubSnapshot) -> Void
    private let pending = Locked(Pending())

    init(queue: DispatchQueue, deliver: @escaping @Sendable (AgentHubSnapshot) -> Void) {
        self.queue = queue
        self.deliver = deliver
    }

    func publish(_ snapshot: AgentHubSnapshot) {
        let schedule = pending.withLock { pending -> Bool in
            pending.latest = snapshot
            defer { pending.isScheduled = true }
            return !pending.isScheduled
        }
        guard schedule else { return }
        queue.async { [self] in
            let snapshot = pending.withLock { pending in
                pending.isScheduled = false
                defer { pending.latest = nil }
                return pending.latest
            }
            if let snapshot { deliver(snapshot) }
        }
    }
}
