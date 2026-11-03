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
/// pending, and a newer one replaces it. Item events and the answers to item calls run on the hub's queue,
/// in the order the connections emitted them, so a call's answer comes before any event it caused.
public final class AgentHub: Sendable {
    /// The hub's queue: serial, every input to its state runs on it.
    package let queue = DispatchQueue(label: "app.kernova.agent-hub")
    private let connector: any HostConnectionMaking
    private let scheduler: any RuntimeScheduler
    private let template: Locked<HostConfigurationTemplate>
    private let handles = Locked<UInt64>(0)
    private let state = Locked(AgentHubState())
    private let publisher: SnapshotPublisher
    private let itemEvents: @Sendable (HubItemEvent) -> Void
    private let logger: KernovaLogger

    /// A hub whose connections say Hello as `claim`, offer `payloads`' bundles and serve their bytes, serve
    /// items through `items`, and start with `policy`; the item events of every connection reach
    /// `itemEvents`.
    public convenience init(
        claim: PeerClaim, policy: PolicySnapshot, payloads: any BundledPayloadProvider, items: ItemAdapters? = nil,
        scheduler: any RuntimeScheduler = SystemScheduler(),
        logger: KernovaLogger = KernovaLogger(subsystem: "app.kernova", category: "AgentHub"),
        itemEvents: @escaping @Sendable (HubItemEvent) -> Void = { _ in },
        publishingOn publishQueue: DispatchQueue = .main,
        _ publish: @escaping @Sendable (AgentHubSnapshot) -> Void
    ) {
        self.init(
            connector: HostConnectionRuntime(
                claim: claim, scheduler: scheduler, payloadSource: payloads, items: items, logger: logger),
            policy: policy, payloads: payloads, scheduler: scheduler, logger: logger, itemEvents: itemEvents,
            publishingOn: publishQueue, publish)
    }

    /// A hub whose connections `connector` builds, stamping when each peer goes away on `scheduler`'s clock.
    public init(
        connector: any HostConnectionMaking, policy: PolicySnapshot, payloads: any BundledPayloadProvider,
        scheduler: any RuntimeScheduler = SystemScheduler(), logger: KernovaLogger,
        itemEvents: @escaping @Sendable (HubItemEvent) -> Void = { _ in }, publishingOn publishQueue: DispatchQueue,
        _ publish: @escaping @Sendable (AgentHubSnapshot) -> Void
    ) {
        self.connector = connector
        self.scheduler = scheduler
        self.logger = logger
        self.itemEvents = itemEvents
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

    // MARK: Power

    /// Routes `action` across the peers (spec §6.4) — `ConsoleAuthority`'s console peers newest first, then
    /// the system peer — and calls `completion` once, on the hub's queue, with how it ended. The hub never
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

    /// Sends `handle`'s connection the routing's request.
    private func ask(_ handle: PeerHandle, _ action: PowerAction) {
        let (connection, id, record) = state.withLock { state in
            // `PowerRouting` asks only a peer of `routingPeers`, read on this queue in the same turn, and a peer
            // lives in its connection's entry.
            guard let entry = state.connections[handle], let record = entry.peer else {
                preconditionFailure("routing asked \(handle), which is no peer of this turn")
            }
            let id = state.power.drawID(entry.connection.generation)
            state.power.requests[id] = handle
            state.power.progress = PowerRoutingProgress(action: action, role: record.claim.role, stage: .asking)
            return (entry.connection, id, record)
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
    private func endPowerRequests(of handle: PeerHandle) {
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

    // MARK: Items

    /// Offers `offer` on `feature` — CLIPBOARD, withdrawing that peer's previous clipboard offer, or DROP —
    /// to the peer the snapshot's `consolePeers` names for it now, and calls `completion` once with that
    /// peer, whose `.items` events then carry the offer, or why it was not opened: `FEATURE_UNAVAILABLE`
    /// with the absence when no console peer offers `feature`. Once that peer is no longer `feature`'s
    /// console peer, the hub withdraws the offer, and its `.offerEnded` follows.
    public func offerItems(
        _ offer: ItemOffer, feature: FeatureID,
        _ completion: @escaping @Sendable (Result<PeerHandle, WireError>) -> Void
    ) {
        queue.async { [self] in
            let route = state.withLock { state in
                state.consolePeer(for: feature).map { Result.success($0) }
                    ?? .failure(WireError(.featureUnavailable, absence: state.consoleAbsence(of: feature)))
            }
            guard case .success(let peer) = route else { return completion(route) }
            awaitReply(
                from: peer, { .offer($0, offer, feature: feature) },
                { if case .offered(let refusal) = $0 { refusal.map(Result.failure) ?? .success(peer) } else { nil } },
                unanswered: .failure(Self.connectionEnded), completion)
        }
    }

    /// Withdraws the offer of `token` made to `peer`; its `.offerEnded` follows.
    public func withdrawOffer(_ token: Data, from peer: PeerHandle) {
        queue.async { [self] in send(.withdraw(token: token), to: peer) }
    }

    /// Releases `peer`'s offer of `token`: the host pulls nothing more of it. Releasing a taken drag offer
    /// completes the drag.
    public func releaseOffer(_ token: Data, of peer: PeerHandle) {
        queue.async { [self] in send(.release(token: token), to: peer) }
    }

    /// Pulls one representation of `peer`'s open offer as `order` says, and calls `completion` once with the
    /// pull's id, whose one `.pullEnded` follows, or why it was not opened: `ITEM_OFFER_STALE` for an offer the
    /// hub has not forwarded, or no longer holds.
    public func pullItem(
        _ order: ItemPullOrder, from peer: PeerHandle,
        _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
    ) {
        queue.async { [self] in
            let (isPeer, feature) = state.withLock {
                ($0.isPeer(peer), $0.forwardedFeature(order.request.token, on: peer))
            }
            if isPeer, feature == nil {
                return completion(.failure(WireError(.itemOfferStale, debugDetail: "the hub holds no such offer")))
            }
            awaitReply(
                from: peer, feature: feature, { .pull($0, order) },
                { if case .pulled(let result) = $0 { result } else { nil } },
                unanswered: .failure(Self.connectionEnded), completion)
        }
    }

    /// Cancels a pull of `peer`'s offer; its `.pullEnded` follows.
    public func cancelPull(_ id: ItemPullID, on peer: PeerHandle) {
        queue.async { [self] in send(.cancel(id), to: peer) }
    }

    /// Takes `peer`'s open drag offer of `token`, and calls `completion` once with the take's id, whose one
    /// `.dragTake(.ended)` follows, or why it was not opened.
    public func takeDrag(
        _ token: Data, of peer: PeerHandle, _ completion: @escaping @Sendable (Result<DragTakeID, WireError>) -> Void
    ) {
        queue.async { [self] in
            awaitReply(
                from: peer, { .takeDrag($0, token: token) }, { if case .took(let result) = $0 { result } else { nil } },
                unanswered: .failure(Self.connectionEnded), completion)
        }
    }

    /// Calls `completion` once with item `item` of `peer`'s open offer of `token`, decoded; nil when no such
    /// item is held.
    public func readItem(
        _ token: Data, item: UInt32, of peer: PeerHandle, _ completion: @escaping @Sendable (OfferedItem?) -> Void
    ) {
        queue.async { [self] in
            awaitReply(
                from: peer, { .read($0, token: token, item: item) },
                { if case .read(let read) = $0 { .some(read) } else { nil } },
                unanswered: nil, completion)
        }
    }

    private static var connectionEnded: WireError { ItemRequests<PeerHandle>.connectionEnded }

    /// Sends `peer`'s connection the command `command` builds around a fresh request id, and calls
    /// `completion` once with what `answer` reads from its reply — or with `unanswered`, at once or later, when
    /// `peer` is no peer or its connection ends without replying.
    private func awaitReply<Answer: Sendable>(
        from peer: PeerHandle, feature: FeatureID? = nil, _ command: (ItemRequestID) -> ItemCommand,
        _ answer: @escaping @Sendable (ItemReply) -> Answer?, unanswered: Answer,
        _ completion: @escaping @Sendable (Answer) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let deliver = ItemRequests<PeerHandle>.answering(answer, unanswered: unanswered, completion)
        let sent = state.withLock { state -> (any HostConnectionHandle, ItemCommand)? in
            guard let entry = state.connections[peer], entry.peer != nil else { return nil }
            let command = state.items.add(peer, command, feature: feature, deliver)
            return (entry.connection, command)
        }
        guard let (connection, command) = sent else { return deliver(nil) }
        connection.send(.items(command))
    }

    private func send(_ command: ItemCommand, to peer: PeerHandle) {
        dispatchPrecondition(condition: .onQueue(queue))
        state.withLock { $0.connections[peer]?.connection }?.send(.items(command))
    }

    /// The connection `handle` ended: every item call asked of it and not answered gets no answer.
    private func endItemRequests(of handle: PeerHandle) {
        for pending in state.withLock({ $0.items.takeAll(of: handle) }) { pending.answer(nil) }
    }

    /// The answer of `handle`'s connection to the item call of `id`: what it opened is recorded before the caller
    /// hears it. One to a call already ended is dropped.
    private func itemReply(_ id: ItemRequestID, _ reply: ItemReply, from handle: PeerHandle) {
        let pending = state.withLock { state in
            let pending = state.items.take(id, from: handle)
            if let pending { state.opened(pending, reply, on: handle) }
            return pending
        }
        pending?.answer(reply)
    }

    /// Carries out console authority: each command it sends, then each end it hands the owner, in order, and
    /// then each console peer that changed.
    private func settleItems() {
        dispatchPrecondition(condition: .onQueue(queue))
        let (ended, changes) = state.withLock { state in
            let ended = state.settleItems().map { end in
                let connection = state.connections[end.handle]?.connection
                return (send: end.command.flatMap { command in connection.map { ($0, command) } }, event: end.event)
            }
            return (ended, state.consoleChanges())
        }
        for end in ended {
            if let (connection, command) = end.send { connection.send(.items(command)) }
            itemEvents(end.event)
        }
        for change in changes { itemEvents(change) }
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
            state.connections[handle] = ConnectionEntry(connection: connection, attachment: attachment)
            return state.isFrozen
        }
        if frozen { connection.send(.setPeerFrozen(true)) }
    }

    /// Updates the state with `update` and sends `command` to every connection, in one step on the queue.
    private func broadcast(_ command: HostCommand, _ update: (inout AgentHubState) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let connections = state.withLock { state in
            update(&state)
            return state.connections.values.map(\.connection)
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
            state.withLock { $0.connections[handle]?.peer?.state = peerState }
        case .featuresChanged(let table):
            state.withLock { $0.connections[handle]?.peer?.features = table }
        case .liveness(let change):
            state.withLock { $0.connections[handle]?.peer?.isResponsive = change == .responsive }
        case .closed(let closure):
            if let record = state.withLock({ $0.connections[handle]?.peer }) {
                logger.log(
                    .notice,
                    "The \(Self.name(record), privacy: .public) left: \(String(describing: closure), privacy: .public)")
            }
            state.withLock { [now = scheduler.now] in $0.closed(handle, at: now) }
            endPowerRequests(of: handle)
            endItemRequests(of: handle)
        case .log(let delivery):
            // Records change no peer state, so the snapshot is not rebuilt.
            return republish(delivery, from: handle)
        case .update(let event):
            logUpdate(event, from: handle)
            state.withLock { $0.updateServed(event, from: handle) }
        case .items(let event):
            // Item events change no peer state, so the snapshot is not rebuilt.
            let (forward, command) = state.withLock { $0.admit(event, from: handle) }
            if let command { send(command, to: handle) }
            if forward { itemEvents(.items(handle, event)) }
            return
        case .dragTake(let event):
            if state.withLock({ $0.admit(event, from: handle) }) { itemEvents(.dragTake(handle, event)) }
            return
        case .itemReply(let id, let reply):
            itemReply(id, reply, from: handle)
            return settleItems()
        case .power(let id, let result):
            return powerResult(id, result)
        case .diagnostic:
            // The driver logs diagnostics itself.
            return
        }
        settleItems()
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
        guard let record = state.withLock({ $0.connections[handle]?.peer }) else { return }
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
        state.withLock { $0.connections[handle]?.connection }?.send(.close(code, retryAfter: retryAfter))
    }

    /// Republishes `delivery` behind its peer's source, `session <id>` or `system` (spec §7.4), a drop
    /// report included, so everything a guest's ring sends stays in the guest namespace under its VM.
    private func republish(_ delivery: LogDelivery, from handle: PeerHandle) {
        let (peer, republisher) = state.withLock { ($0.connections[handle]?.peer, $0.republisher) }
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
