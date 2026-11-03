#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a peer endpoint is created with: who it is, its state, and each
/// implemented feature's current availability from the adapters' last reports.
public struct PeerConfiguration: Sendable {
    /// The peer's claim, its process's instance id included.
    public var claim: PeerClaim
    /// The initial session state.
    public var state: PeerSessionState
    /// The power adapter's availability; absent `NOT_IMPLEMENTED` without one.
    public var power: Availability<PowerOffer>
    /// The process's power ledger: the request the adapter still holds from an
    /// earlier connection, which a new request waits behind.
    public var powerLedger = PowerLedger()
    /// Whether this build forwards logs.
    public var logs: Availability<NoParams>
    /// The installer's formats and rejected hash; absent `NOT_IMPLEMENTED` without one.
    public var update: Availability<UpdateOffer>
    /// The receiver policy the host is judged by.
    public var receiverPolicy: ReceiverPolicy = .production
    /// What this side serves of item transfer, clipboard, drop and drag. A system peer advertises the last
    /// three absent `NOT_SERVED_BY_ROLE` whatever this says.
    public var items = ItemFeatureAvailability.notImplemented
    package var tweak: @Sendable (inout ConnectionConfiguration) -> Void = { _ in }

    /// Creates a configuration.
    public init(
        claim: PeerClaim, state: PeerSessionState, power: Availability<PowerOffer>, logs: Availability<NoParams>,
        update: Availability<UpdateOffer>
    ) {
        self.claim = claim
        self.state = state
        self.power = power
        self.logs = logs
        self.update = update
    }
}

/// Everything a peer's adapters and runtime feed its endpoint.
public enum PeerInput: Sendable, Equatable {
    /// The session state changed.
    case peerState(PeerSessionState)
    /// The power adapter's report.
    case power(PowerInput)
    /// The log sink's or runtime's input.
    case logs(LogInput)
    /// The installer's report.
    case update(UpdateInput)
    /// The item source's answer or the item sink's report; one naming another generation is dropped.
    case items(ItemTransferInput)
    /// The answer to a take of this side's drag; one to a take already ended is dropped.
    case dragTake(DragTakeID, DragTakeAnswer)
    /// Offer, withdraw, release, pull, cancel or read items; answered as `ItemCommand` says.
    case itemCommand(ItemCommand)
}

/// What a peer endpoint asks its adapters and runtime to do.
public enum PeerEffect: Sendable, Equatable {
    /// For the power adapter.
    case power(PowerEffect)
    /// For the log ring and its runtime.
    case logs(LogEffect)
    /// For the installer.
    case update(UpdateEffect)
    /// For the item source.
    case itemSource(ItemSourceEffect)
    /// For the item sink.
    case itemSink(ItemSinkEffect)
}

/// What a peer endpoint tells the shell's UI and the dial schedule.
public enum PeerEvent: Sendable, Equatable {
    /// The host's Hello was read.
    case established(host: PeerClaim)
    /// A `PolicyUpdate` arrived (coalesced).
    case policyReceived
    /// A liveness verdict about the host.
    case hostLiveness(LivenessChange)
    /// What the host offers (coalesced).
    case updateAvailable(UpdateManifestValue?)
    /// An offer or pull of item transfer changed.
    case items(ItemTransferEvent)
    /// The host takes this side's drag.
    case dragTake(DragTakeEvent)
    /// A feature that offers items became usable on the connection, or stopped being usable: the Hello, the
    /// adverts and the host's policy decide it, and the connection's end makes every one unusable. Once per
    /// change, after the event that caused it and before anything the change ends.
    case itemFeatureUsable(FeatureID, Bool)
    /// The answer to the `.itemCommand` input of this id.
    case itemReply(ItemRequestID, ItemReply)
    /// A note for the runtime's log.
    case diagnostic(Diagnostic)
    /// The connection ended.
    case closed(ConnectionClosure)
}

/// One peer connection's whole state, owned by its driver.
public struct PeerEndpoint: Sendable {
    package private(set) var connection: Connection
    private var power: PowerResponder
    private var logs: LogForwarder
    private var update: UpdateClient
    private var items: ItemMachines
    package var testSink = TestBulkSink()
    /// The connection this endpoint runs.
    public let generation: ConnectionGeneration
    private var effects = OutputQueue<PeerEffect, NoSlot>()
    private var events = OutputQueue<PeerEvent, PeerEventSlot>()
    /// The features that offer items `.itemFeatureUsable` last said are usable.
    private var usableItemFeatures: Set<FeatureID> = []

    /// Creates the endpoint of a connection that just connected.
    public init(_ configuration: PeerConfiguration, generation: ConnectionGeneration, now: CoreInstant) {
        self.generation = generation
        power = PowerResponder(
            availability: configuration.power, ledger: configuration.powerLedger, generation: generation)
        logs = LogForwarder(availability: configuration.logs)
        update = UpdateClient(
            availability: configuration.update, ownHash: configuration.claim.payloadHash, generation: generation)
        items = ItemMachines(configuration.items, role: configuration.claim.role, generation: generation)
        var connectionConfiguration = ConnectionConfiguration(
            claim: configuration.claim, initialState: configuration.state, adverts: [],
            policy: configuration.receiverPolicy)
        connectionConfiguration.adverts =
            [(.power, power.localAdvert), (.update, update.localAdvert), (.logs, logs.localAdvert)] + items.adverts
        configuration.tweak(&connectionConfiguration)
        connection = Connection(connectionConfiguration, now: now)
    }

    /// The connection's phase.
    public var state: ConnectionState { connection.state }

    /// Whether a committed pull's `.pullEnded` is still owed, which its sink's publish report brings, though
    /// the connection may have finished.
    public var hasLandingsInFlight: Bool { items.hasLandingsInFlight }

    /// When the driver must next call `handleTimeout`: the soonest of the
    /// connection's deadline and every machine's, each computed from the clock now.
    public var nextDeadline: CoreInstant? {
        guard connection.state != .finished else { return nil }
        let clock = connection.clock
        let machines = [
            power.nextDeadline(on: clock), logs.nextDeadline(on: clock), update.nextDeadline(on: clock),
            items.nextDeadline(on: clock),
        ]
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

    /// The transmit marked `isFinal` was written in full.
    public mutating func finalTransmitWritten(now: CoreInstant) {
        connection.finalTransmitWritten(now: now)
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

    /// An adapter's or the runtime's input.
    public mutating func handle(_ input: PeerInput, now: CoreInstant) {
        connection.tick(now)
        route(now)
        switch input {
        case .peerState(let state):
            if connection.isAcceptingInput { connection.setPeerState(state) }
        case .power(let input):
            power.handle(input: input, connection: &connection, now: now)
        case .logs(let input):
            logs.handle(input: input, connection: &connection, now: now)
        case .update(let input):
            update.handle(input: input, connection: &connection, now: now)
        case .items(let input):
            items.handle(input, connection: &connection, now: now)
        case .dragTake(let id, let answer):
            items.answer(id, answer, connection: &connection)
        case .itemCommand(let command):
            // Queued before the route below collects what the command caused, so the answer comes first.
            if let (id, reply) = items.perform(command, connection: &connection) {
                events.append(.itemReply(id, reply))
            }
        }
        route(now)
    }

    /// Closes the connection, the agent exiting (`SHUTTING_DOWN`).
    public mutating func close(_ code: ErrorCode, now: CoreInstant) {
        connection.close(code, retryAfter: nil, now: now)
        route(now)
    }

    /// Opens a bulk test stream.
    package mutating func openTestBulk(_ kind: StreamKind, consumes: Bool, now: CoreInstant) -> StreamID? {
        connection.tick(now)
        route(now)
        let stream = testSink.open(kind, consumes: consumes, connection: &connection)
        route(now)
        return stream
    }

    package mutating func resetTestStream(_ stream: StreamID, now: CoreInstant) {
        connection.tick(now)
        testSink.reset(stream, connection: &connection)
        route(now)
    }

    package mutating func setTestConsumes(_ consumes: Bool, on stream: StreamID, now: CoreInstant) {
        connection.tick(now)
        testSink.setConsumes(consumes, on: stream, connection: &connection)
        route(now)
    }

    // MARK: Items

    package var itemOffers: ItemOfferRegistry { items.transfer.offers }

    // MARK: Outputs

    /// The next frames to write.
    public mutating func pollTransmit(maxBytes: Int) -> Transmit? {
        let transmit = connection.pollTransmit(maxBytes: maxBytes)
        route(connection.clock.raw)
        return transmit
    }

    /// The next effect for an adapter.
    public mutating func pollEffect() -> PeerEffect? {
        effects.poll()
    }

    /// The next event for the shell.
    public mutating func pollEvent() -> PeerEvent? {
        events.poll()
    }

    /// Events not yet polled.
    package var pendingEventCount: Int { events.count }

    package mutating func takeTrace() -> [ConnectionTrace] {
        connection.takeTrace()
    }

    // MARK: Routing

    private mutating func route(_ now: CoreInstant) {
        while true {
            collect()
            if let routed = connection.pollRoutedEvent() {
                dispatch(routed, now)
            } else if publishAdverts() {
                notifyAll(.usabilityChanged, now)
                refreshItemUsability()
            } else {
                break
            }
        }
    }

    private mutating func publishAdverts() -> Bool {
        let adverts: [(FeatureID, LocalAdvert)] =
            [(.power, power.localAdvert), (.update, update.localAdvert), (.logs, logs.localAdvert)] + items.adverts
        let before = connection.localAdverts
        connection.setLocalAdverts(adverts)
        return connection.localAdverts != before && connection.state == .established
    }

    private mutating func notifyAll(_ event: FeatureEvent, _ now: CoreInstant) {
        power.handle(event, connection: &connection, now: now)
        logs.handle(event, connection: &connection, now: now)
        update.handle(event, connection: &connection, now: now)
        items.notify(event, connection: &connection, now: now)
    }

    private mutating func dispatch(_ routed: RoutedEvent, _ now: CoreInstant) {
        let event = routed.event
        switch event {
        case .helloReceived(let hello):
            events.append(.established(host: hello.claim))
            notifyAll(.sessionEstablished, now)
            refreshItemUsability()
        case .remoteAdvertsChanged:
            notifyAll(.usabilityChanged, now)
            refreshItemUsability()
        case .peerStateChanged:
            break
        case .policyChanged:
            events.append(.policyReceived, coalescing: .policy)
            notifyAll(.policyChanged, now)
            notifyAll(.usabilityChanged, now)
            refreshItemUsability()
        case .updateAvailable(let manifest):
            events.append(.updateAvailable(manifest), coalescing: .updateAvailable)
            update.offerChanged(manifest, connection: &connection)
        case .liveness(let change):
            events.append(.hostLiveness(change))
        case .diagnostic(let diagnostic):
            events.append(.diagnostic(diagnostic))
        case .closed(let closure):
            refreshItemUsability(closed: true)
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
        case .slotFreed:
            // The slots are shared across kinds, so every opener re-checks.
            notifyAll(.slotFreed, now)
        }
    }

    /// Emits `.itemFeatureUsable` for each feature that offers items whose usability changed; with `closed`,
    /// every one is unusable.
    private mutating func refreshItemUsability(closed: Bool = false) {
        for feature in ItemFeatureAvailability.offering.sorted(by: { $0.rawValue < $1.rawValue }) {
            let usable = !closed && connection.usability(feature).isAvailable
            guard usable != usableItemFeatures.contains(feature) else { continue }
            if usable { usableItemFeatures.insert(feature) } else { usableItemFeatures.remove(feature) }
            events.append(.itemFeatureUsable(feature, usable))
        }
    }

    private mutating func deliver(_ event: FeatureEvent, to owner: KindOwner?, _ now: CoreInstant) {
        guard let owner else { return }
        switch owner {
        case .power: power.handle(event, connection: &connection, now: now)
        case .update: update.handle(event, connection: &connection, now: now)
        case .logs: logs.handle(event, connection: &connection, now: now)
        case .itemTransfer, .itemOffer, .dragTake: items.deliver(event, to: owner, connection: &connection, now: now)
        case .testBulk: testSink.handle(event, connection: &connection)
        }
    }

    private mutating func collect() {
        for output in [power.takeOutputs(), logs.takeOutputs(), update.takeOutputs()] {
            for effect in output.effects { effects.append(effect) }
            for diagnostic in output.diagnostics {
                connection.diagnose(diagnostic)
            }
        }
        let outputs = items.takeOutputs()
        for output in outputs.items {
            switch output {
            case .source(let effect): effects.append(.itemSource(effect))
            case .sink(let effect): effects.append(.itemSink(effect))
            case .event(let event): events.append(.items(event))
            }
        }
        for event in outputs.drag { events.append(.dragTake(event)) }
        for diagnostic in outputs.diagnostics { connection.diagnose(diagnostic) }
    }
}

/// The peer's events that coalesce.
enum PeerEventSlot: Hashable, Sendable {
    case policy, updateAvailable
}
