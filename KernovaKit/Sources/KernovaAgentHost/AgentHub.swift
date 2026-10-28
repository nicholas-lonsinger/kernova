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

/// A provider bundling nothing.
public struct NoBundledPayloads: BundledPayloadProvider {
    /// The provider.
    public init() {}

    /// Answers no payloads, at once.
    public func loadPayloads(_ completion: @escaping @Sendable ([BundledPayload]) -> Void) {
        completion([])
    }

    /// Fails every read `READ_FAILED`: nothing is offered, so nothing is pulled.
    public func read(
        manifest: UpdateManifestValue, offset: UInt64, count: Int,
        _ completion: @escaping @Sendable (Result<Data, WireError>) -> Void
    ) {
        completion(.failure(WireError(.readFailed, debugDetail: "the host bundles no payload")))
    }
}

/// What a host connection is built with, as of now: read at accept, so a connection's Hello is
/// answered from the configuration current when it was accepted (spec §4.1.5).
struct HostConfigurationTemplate: Sendable {
    var policy: PolicySnapshot
    var bundles: [BundledPayload] = []
}

/// Builds the hub's host connections.
package protocol HostConnectionMaking: Sendable {
    /// A connection over `stream`, not yet started, whose events reach `handler` on `queue`.
    func makeConnection(
        _ stream: any ByteStream, policy: PolicySnapshot, bundles: [BundledPayload],
        deliveringOn queue: DispatchQueue, _ handler: @escaping @Sendable (HostEvent) -> Void
    ) -> any HostConnectionHandle
}

/// One host connection, as the hub drives it.
package protocol HostConnectionHandle: Sendable {
    /// Starts the connection.
    func start()
    /// Sends `command` to the connection's driver with `async`.
    func send(_ command: HostCommand)
}

extension HostConnectionRuntime: HostConnectionMaking {
    package func makeConnection(
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
    package init(
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

    /// Starts accepting through `transport` with `policy` current, republishing guest logs through
    /// `republisher`; a transport attached before is detached first.
    public func attach(
        _ transport: any GuestStreamTransport, policy: PolicySnapshot, republisher: GuestLogRepublisher
    ) {
        setPolicy(policy)
        queue.async { [self] in
            let (attached, previous) = state.withLock { state -> (Bool, (any GuestStreamTransport)?) in
                guard !state.isClosed else { return (false, nil) }
                defer {
                    state.transport = transport
                    state.republisher = republisher
                }
                return (true, state.transport)
            }
            previous?.stop()
            guard attached else { return }
            transport.start { [self] stream in accept(stream) }
        }
    }

    /// Stops the attached transport: it accepts nothing more and shuts down every stream, so each
    /// connection ends as its transport does.
    public func detach() {
        queue.async { [self] in
            state.withLock { state in
                defer { state.transport = nil }
                return state.transport
            }?.stop()
        }
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

    /// Closes every connection `SHUTTING_DOWN` and stops the transport; the hub accepts nothing more.
    public func close() {
        queue.async { [self] in
            let transport = state.withLock { state in
                state.isClosed = true
                defer { state.transport = nil }
                return state.transport
            }
            transport?.stop()
            broadcast(.close(.shuttingDown, retryAfter: nil)) { _ in }
        }
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
        let (frozen, closed) = state.withLock { state in
            state.connections[handle] = connection
            return (state.isFrozen, state.isClosed)
        }
        if frozen { connection.send(.setPeerFrozen(true)) }
        if closed { connection.send(.close(.shuttingDown, retryAfter: nil)) }
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
        case .log(let delivery):
            republish(delivery, from: handle)
        case .closed:
            state.withLock { $0.closed(handle) }
        case .power, .update, .diagnostic:
            // Nothing asks a peer for power or serves its pulls' progress yet, and the driver logs
            // diagnostics itself.
            break
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

    private func republish(_ delivery: LogDelivery, from handle: PeerHandle) {
        let (peer, republisher) = state.withLock { ($0.peers[handle], $0.republisher) }
        guard let peer else { return }
        let role = peer.claim.role == .systemPeer ? "system" : "session"
        switch delivery {
        case .records(let records):
            guard let republisher else { return }
            let source = peer.claim.role == .systemPeer ? role : "\(role) \(peer.state.sessionID)"
            for record in records {
                republisher.republish(
                    KernovaLogLevel(record.level), prefix: "[\(source) \(record.subsystem)/\(record.category)] ",
                    record.segments.map { LogSegment(text: $0.text, isPrivate: $0.isPrivate) })
            }
        case .dropped(let count):
            logger.log(
                .notice,
                "Guest \(role, privacy: .public) dropped \(count) log record(s) while the host was behind")
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
