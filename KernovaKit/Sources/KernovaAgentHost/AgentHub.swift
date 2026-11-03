#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaDigest
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
    private let scheduler: any RuntimeScheduler
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
            policy: policy, payloads: payloads, scheduler: scheduler, logger: logger, publishingOn: publishQueue,
            publish)
    }

    /// A hub whose connections `connector` builds, stamping when each peer goes away on `scheduler`'s clock.
    public init(
        connector: any HostConnectionMaking, policy: PolicySnapshot, payloads: any BundledPayloadProvider,
        scheduler: any RuntimeScheduler = SystemScheduler(), logger: KernovaLogger,
        publishingOn publishQueue: DispatchQueue, _ publish: @escaping @Sendable (AgentHubSnapshot) -> Void
    ) {
        self.connector = connector
        self.scheduler = scheduler
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
            let generation = state.withLock { state -> UInt64? in
                guard !state.isClosed else { return nil }
                state.republisher = republisher
                state.attachmentGeneration += 1
                return state.attachmentGeneration
            }
            guard let generation else { return }
            let acceptor = GuestStreamAcceptor(logger: logger) { [self] stream in accept(stream, attachment: generation)
            }
            detachTransport()
            state.withLock { $0.attachment = (transport, acceptor) }
            transport.start(admitting: acceptor)
            publishIfChanged()
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

    private func detachTransport() {
        dispatchPrecondition(condition: .onQueue(queue))
        let attachment = state.withLock { state in
            defer {
                state.attachment = nil
                state.resetAttachmentMemory()
            }
            return state.attachment
        }
        publishIfChanged()
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
    private func accept(_ stream: any ByteStream, attachment: UInt64) {
        let handle = PeerHandle(
            rawValue: handles.withLock { count in
                count += 1
                return count
            })
        let connection = template.withLock { template in
            let connection = connector.makeConnection(
                stream, policy: template.policy, bundles: template.bundles, deliveringOn: queue
            ) { [self] event in receive(event, from: handle) }
            queue.async { [self] in register(handle, connection, attachment: attachment) }
            return connection
        }
        connection.start()
    }

    private func register(_ handle: PeerHandle, _ connection: any HostConnectionHandle, attachment: UInt64) {
        let frozen = state.withLock { state in
            state.connections[handle] = connection
            state.connectionAttachments[handle] = attachment
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
            logHello(claim, peerState, outcome)
            resolve(outcome, incoming: handle)
        case .peerStateChanged(let peerState):
            state.withLock { $0.peers[handle]?.state = peerState }
        case .featuresChanged(let table):
            state.withLock { $0.peers[handle]?.features = table }
        case .liveness(let change):
            state.withLock { $0.peers[handle]?.isResponsive = change == .responsive }
        case .closed(let closure):
            if let record = state.withLock({ $0.peers[handle] }) {
                logger.log(
                    .notice,
                    "The \(Self.name(record), privacy: .public) left: \(String(describing: closure), privacy: .public)")
            }
            state.withLock { [now = scheduler.now] in $0.closed(handle, at: now) }
        case .log(let delivery):
            // Records change no peer state, so the snapshot is not rebuilt.
            return republish(delivery, from: handle)
        case .update(let event):
            logUpdate(event, from: handle)
            state.withLock { $0.updateServed(event, from: handle) }
        case .items(let event):
            // The hub offers and pulls no items, so no item event changes what it does.
            if let record = state.withLock({ $0.peers[handle] }) {
                logger.log(
                    .notice,
                    "The hub does not act on the \(Self.name(record), privacy: .public)'s item event \(Self.kind(event), privacy: .public)"
                )
            }
            return
        case .power, .diagnostic:
            // Nothing asks a peer for power yet, and the driver logs diagnostics itself.
            return
        }
        publishIfChanged()
    }

    /// Logs a Hello read: who the peer is, what it runs, and whether it joined.
    private func logHello(_ claim: PeerClaim, _ peerState: PeerSessionState, _ outcome: HelloOutcome?) {
        let peer =
            claim.role == .systemPeer
            ? "system peer" : "session peer (session \(peerState.sessionID), user \(peerState.userName))"
        let joined =
            switch outcome {
            case .joined: "joined"
            case .displaced: "joined, displacing the peer it replaces"
            case .refused(let code, _): "refused: \(code)"
            case nil: "of a connection already gone"
            }
        logger.log(
            .notice,
            """
            Hello from the \(peer, privacy: .public): version \(claim.versionLabel, privacy: .public), payload \
            \(lowercaseHex(claim.payloadHash), privacy: .public); \(joined, privacy: .public)
            """)
    }

    private func logUpdate(_ event: UpdateServeEvent, from handle: PeerHandle) {
        guard let record = state.withLock({ $0.peers[handle] }) else { return }
        let peer = Self.name(record)
        switch event {
        case .pullRequested(_, let manifest):
            logger.log(.notice, "The \(peer, privacy: .public) pulls update \(manifest.versionLabel, privacy: .public)")
        case .result(_, let result) where result.kind == .staged:
            logger.log(.notice, "The \(peer, privacy: .public) installed the update and relaunches")
        case .result(_, let result):
            let code = String(describing: result.error?.code)
            logger.log(.error, "The \(peer, privacy: .public) refused the update: \(code, privacy: .public)")
        case .closed(_, let closure):
            let detail = String(describing: closure)
            logger.log(.error, "The \(peer, privacy: .public)'s update pull ended early: \(detail, privacy: .public)")
        }
    }

    private static func kind(_ event: ItemTransferEvent) -> String {
        switch event {
        case .offerReceived: "offerReceived"
        case .offerEnded: "offerEnded"
        case .pullEnded: "pullEnded"
        case .serveEnded: "serveEnded"
        }
    }

    private static func name(_ record: PeerRecord) -> String {
        switch record.claim.role {
        case .systemPeer: "system peer"
        case .sessionPeer, .host:
            "session peer (session \(record.state.sessionID), user \(record.state.userName))"
        }
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
