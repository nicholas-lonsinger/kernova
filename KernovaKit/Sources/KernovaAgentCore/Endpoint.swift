#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What an endpoint tells its owner: its role's own events, and what every endpoint reports of item transfer and
/// of the connection.
public enum EndpointEvent<RoleEvent: Sendable & Equatable>: Sendable, Equatable {
    /// An event of the role's own.
    case role(RoleEvent)
    /// A liveness verdict about the far side.
    case liveness(LivenessChange)
    /// An offer or pull of item transfer changed.
    case items(ItemTransferEvent)
    /// A take of a drag changed: on the host, one it opened of the peer's drag; on a peer, the host's take of
    /// this side's.
    case dragTake(DragTakeEvent)
    /// The answer to the item command of this id.
    case itemReply(ItemRequestID, ItemReply)
    /// A note for the runtime's log.
    case diagnostic(Diagnostic)
    /// The connection ended.
    case closed(ConnectionClosure)
}

/// What an endpoint asks its adapters to do: its role's own effects, and what every endpoint asks of its item
/// adapters.
public enum EndpointEffect<RoleEffect: Sendable & Equatable>: Sendable, Equatable {
    /// An effect of the role's own.
    case role(RoleEffect)
    /// For the item source.
    case itemSource(ItemSourceEffect)
    /// For the item sink.
    case itemSink(ItemSinkEffect)
}

/// What every endpoint's configuration holds.
package protocol EndpointConfiguration: Sendable {
    /// This side's claim.
    var claim: PeerClaim { get }
    /// What this side serves of item transfer, clipboard, drop and drag.
    var items: ItemFeatureAvailability { get }
    /// The connection's configuration, before the endpoint adds its machines' adverts.
    var connectionConfiguration: ConnectionConfiguration { get }
    #if DEBUG
    /// Changes the connection's configuration once the endpoint has built it.
    var tweakForTesting: @Sendable (inout ConnectionConfiguration) -> Void { get }
    #endif
}

/// What a role adds to the endpoint every role shares: its power, logs and update machines, its inputs, and what
/// its owner hears.
package protocol RoleMachines: Sendable {
    associatedtype Configuration: EndpointConfiguration
    associatedtype Input: Sendable
    associatedtype Event: Sendable & Equatable
    associatedtype Effect: Sendable & Equatable
    associatedtype EventSlot: Hashable & Sendable
    associatedtype Power: FeatureMachine where Power.Event == Event, Power.Effect == Effect
    associatedtype Logs: FeatureMachine where Logs.Event == Event, Logs.Effect == Effect
    associatedtype Update: FeatureMachine where Update.Event == Event, Update.Effect == Effect

    /// POWER's machine.
    var power: Power { get set }
    /// LOGS's machine.
    var logs: Logs { get set }
    /// UPDATE's machine.
    var update: Update { get set }

    /// The machines of a connection just made from `configuration`.
    init(_ configuration: Configuration, generation: ConnectionGeneration)

    /// The slot `event` coalesces in; nil for one that never does.
    static func slot(of event: Event) -> EventSlot?

    /// Carries out `input` on the connection and the role's machines, and returns what of it is the endpoint's to
    /// carry out.
    mutating func handle(_ input: Input, connection: inout Connection, now: CoreInstant) -> SharedInput?

    /// Handles `message` on the connection and the role's machines, and returns what the owner hears of it and what
    /// of it is the endpoint's to carry out.
    mutating func receive(
        _ message: SessionMessage, connection: inout Connection
    ) -> (event: Event?, shared: SharedInput?)

    /// What the owner hears of a change, since the last report, in which features are usable on `connection`, or
    /// once it is `closed`.
    mutating func reportUsability(of connection: Connection, closed: Bool) -> [Event]
}

/// A session message from the far side whose handling is the role's.
package enum SessionMessage: Sendable {
    /// The far side's Hello.
    case hello(RemoteHello)
    /// A `PeerState`, which only a peer sends.
    case peerState(PeerSessionState)
    /// A `PolicyUpdate`, which only the host sends.
    case policy(PolicySnapshot)
    /// An `UpdateAvailable`, which only the host sends.
    case updateAvailable(UpdateManifestValue?)
}

/// What a role's input or session message leaves to the endpoint.
package enum SharedInput: Sendable {
    /// Carry out an item command, answering it before anything it causes.
    case itemCommand(ItemCommand)
    /// The item source's answer or the item sink's report.
    case items(ItemTransferInput)
    /// The answer to a take of this side's drag.
    case dragTake(DragTakeID, DragTakeAnswer)
    /// The policy changed: every machine hears it, then that usability may have changed.
    case policyChanged
}

/// One connection's whole state, owned by its driver: the connection, the role's machines, and the item machines.
package struct Endpoint<Role: RoleMachines>: Sendable {
    package private(set) var connection: Connection
    private var role: Role
    private var items: ItemMachines
    #if DEBUG
    package var testSink = TestBulkSink()
    #endif
    /// The connection this endpoint runs.
    package let generation: ConnectionGeneration
    private var events = OutputQueue<EndpointEvent<Role.Event>, Role.EventSlot>()
    private var effects = OutputQueue<EndpointEffect<Role.Effect>, NoSlot>()

    /// Creates the endpoint of a connection that just connected.
    package init(_ configuration: Role.Configuration, generation: ConnectionGeneration, now: CoreInstant) {
        self.generation = generation
        let role = Role(configuration, generation: generation)
        let items = ItemMachines(configuration.items, role: configuration.claim.role, generation: generation)
        var connectionConfiguration = configuration.connectionConfiguration
        connectionConfiguration.adverts = Self.adverts(role, items)
        #if DEBUG
        configuration.tweakForTesting(&connectionConfiguration)
        #endif
        self.role = role
        self.items = items
        connection = Connection(connectionConfiguration, now: now)
    }

    /// The connection's phase.
    package var state: ConnectionState { connection.state }

    /// Whether a committed pull's `.pullEnded` is still owed, which its sink's publish report brings, though
    /// the connection may have finished.
    package var hasLandingsInFlight: Bool { items.hasLandingsInFlight }

    /// When the driver must next call `handleTimeout`: the soonest of the connection's deadline and its machines',
    /// each computed from the clock now.
    package var nextDeadline: CoreInstant? {
        guard connection.state != .finished else { return nil }
        let clock = connection.clock
        let machines = [
            role.power.nextDeadline(on: clock), role.logs.nextDeadline(on: clock), role.update.nextDeadline(on: clock),
        ]
        return ([connection.nextDeadline] + machines.map(clock.external)).compactMap { $0 }.min()
    }

    // MARK: Inputs

    /// Bytes from the transport.
    package mutating func receive(_ bytes: Data, now: CoreInstant) {
        connection.ingest(bytes, now: now)
        route()
        while connection.processNextFrame() {
            route()
        }
        connection.finishReceive()
        route()
    }

    /// The transmit marked `isFinal` was written in full.
    package mutating func finalTransmitWritten(now: CoreInstant) {
        connection.finalTransmitWritten(now: now)
        route()
    }

    /// The transport ended.
    package mutating func transportEnded(now: CoreInstant) {
        connection.transportEnded(now: now)
        route()
    }

    /// The timer fired.
    package mutating func handleTimeout(now: CoreInstant) {
        connection.handleTimeout(now: now)
        route()
        notifyAll(.deadline)
        route()
    }

    /// An input from the endpoint's owner or adapters.
    package mutating func handle(_ input: Role.Input, now: CoreInstant) {
        step(at: now) { endpoint in
            guard let shared = endpoint.role.handle(input, connection: &endpoint.connection, now: now) else { return }
            endpoint.perform(shared)
        }
    }

    /// Closes the connection with `code` and no retry delay.
    package mutating func close(_ code: ErrorCode, now: CoreInstant) {
        step(at: now) { $0.connection.close(code, retryAfter: nil, now: now) }
    }

    // MARK: Outputs

    /// The next frames to write.
    package mutating func pollTransmit(maxBytes: Int) -> Transmit? {
        let transmit = connection.pollTransmit(maxBytes: maxBytes)
        route()
        return transmit
    }

    /// The next event for the owner.
    package mutating func pollEvent() -> EndpointEvent<Role.Event>? {
        events.poll()
    }

    /// The next effect for an adapter.
    package mutating func pollEffect() -> EndpointEffect<Role.Effect>? {
        effects.poll()
    }

    #if DEBUG
    // MARK: Testing

    /// Opens a bulk test stream.
    package mutating func openTestBulk(_ kind: StreamKind, consumes: Bool, now: CoreInstant) -> StreamID? {
        step(at: now) { $0.testSink.open(kind, consumes: consumes, connection: &$0.connection) }
    }

    /// Resets the bulk test stream `stream` with CANCELLED.
    package mutating func resetTestStream(_ stream: StreamID, now: CoreInstant) {
        step(at: now) { $0.testSink.reset(stream, connection: &$0.connection) }
    }

    /// Starts or stops consuming on the bulk test stream `stream`.
    package mutating func setTestConsumes(_ consumes: Bool, on stream: StreamID, now: CoreInstant) {
        step(at: now) { $0.testSink.setConsumes(consumes, on: stream, connection: &$0.connection) }
    }

    /// The item offers both sides hold open.
    package var itemOffersForTesting: ItemOfferRegistry { items.transfer.offers }

    /// Events not yet polled.
    package var pendingEventCountForTesting: Int { events.countForTesting }

    /// Takes the connection's trace, emptying it.
    package mutating func takeTraceForTesting() -> [ConnectionTrace] {
        connection.takeTraceForTesting()
    }
    #endif

    // MARK: Routing

    /// Runs `body` as one input: the clock advances to `now`, and what that caused is routed before what `body` did.
    private mutating func step<Result>(at now: CoreInstant, _ body: (inout Self) -> Result) -> Result {
        connection.tick(now)
        route()
        let result = body(&self)
        route()
        return result
    }

    private mutating func perform(_ input: SharedInput) {
        switch input {
        case .itemCommand(let command):
            // Queued now, while what the command caused waits for the route that ends the input, so the answer
            // comes first.
            if let (id, reply) = items.perform(command, connection: &connection) {
                events.append(.itemReply(id, reply))
            }
        case .items(let input):
            items.handle(input, connection: &connection)
        case .dragTake(let id, let answer):
            items.answer(id, answer, connection: &connection)
        case .policyChanged:
            policyChanged()
        }
    }

    private mutating func route() {
        while true {
            collect()
            if let routed = connection.pollRoutedEvent() {
                dispatch(routed)
            } else if republishAdverts() {
                usabilityChanged()
            } else {
                break
            }
        }
    }

    private static func adverts(_ role: Role, _ items: ItemMachines) -> [(FeatureID, LocalAdvert)] {
        [(.power, role.power.localAdvert), (.update, role.update.localAdvert), (.logs, role.logs.localAdvert)]
            + items.adverts
    }

    /// Gives the connection the machines' adverts; true when that changed the adverts of an established connection.
    private mutating func republishAdverts() -> Bool {
        let before = connection.localAdverts
        connection.setLocalAdverts(Self.adverts(role, items))
        return connection.localAdverts != before && connection.state == .established
    }

    private mutating func notifyAll(_ event: FeatureEvent) {
        role.power.handle(event, connection: &connection)
        role.logs.handle(event, connection: &connection)
        role.update.handle(event, connection: &connection)
        items.notify(event, connection: &connection)
    }

    private mutating func policyChanged() {
        notifyAll(.policyChanged)
        usabilityChanged()
    }

    private mutating func usabilityChanged() {
        notifyAll(.usabilityChanged)
        reportUsability()
    }

    private mutating func receive(_ message: SessionMessage) {
        let (event, shared) = role.receive(message, connection: &connection)
        if let event { emit(event) }
        if let shared { perform(shared) }
    }

    private mutating func reportUsability(closed: Bool = false) {
        for event in role.reportUsability(of: connection, closed: closed) { emit(event) }
    }

    private mutating func emit(_ event: Role.Event) {
        events.append(.role(event), coalescing: Role.slot(of: event))
    }

    private mutating func dispatch(_ routed: RoutedEvent) {
        switch routed.event {
        case .helloReceived(let hello):
            receive(.hello(hello))
            notifyAll(.sessionEstablished)
            reportUsability()
        case .remoteAdvertsChanged:
            usabilityChanged()
        case .peerStateChanged(let state):
            receive(.peerState(state))
        case .policyChanged(let policy):
            receive(.policy(policy))
        case .updateAvailable(let manifest):
            receive(.updateAvailable(manifest))
        case .liveness(let change):
            events.append(.liveness(change))
        case .diagnostic(let diagnostic):
            events.append(.diagnostic(diagnostic))
        case .closed(let closure):
            reportUsability(closed: true)
            events.append(.closed(closure))
        case .opened(let id, _, let body):
            deliver(.opened(id, body: body), to: routed.owner)
        case .message(let id, let payload):
            deliver(.message(id, payload), to: routed.owner)
        case .data(let id, let payload):
            deliver(.data(id, payload), to: routed.owner)
        case .remoteEnded(let id, let body):
            deliver(.remoteEnded(id, body: body), to: routed.owner)
        case .writable(let id):
            deliver(.writable(id), to: routed.owner)
        case .streamClosed(let id, let closure):
            deliver(.streamClosed(id, closure), to: routed.owner)
        case .slotFreed:
            // The slots are shared across kinds, so every opener re-checks.
            notifyAll(.slotFreed)
        }
    }

    private mutating func deliver(_ event: FeatureEvent, to owner: KindOwner?) {
        guard let owner else { return }
        switch owner {
        case .power: role.power.handle(event, connection: &connection)
        case .update: role.update.handle(event, connection: &connection)
        case .logs: role.logs.handle(event, connection: &connection)
        case .itemTransfer, .itemOffer, .dragTake: items.deliver(event, to: owner, connection: &connection)
        #if DEBUG
        case .testBulk: testSink.handle(event, connection: &connection)
        #endif
        }
    }

    private mutating func collect() {
        let machines = [role.power.takeOutputs(), role.logs.takeOutputs(), role.update.takeOutputs()]
        for effect in machines.flatMap(\.effects) { effects.append(.role(effect)) }
        let outputs = items.takeOutputs()
        for output in outputs.items {
            switch output {
            case .source(let effect): effects.append(.itemSource(effect))
            case .sink(let effect): effects.append(.itemSink(effect))
            case .event(let event): events.append(.items(event))
            case .reply(let id, let reply): events.append(.itemReply(id, reply))
            }
        }
        for event in outputs.drag { events.append(.dragTake(event)) }
        for event in machines.flatMap(\.events) { emit(event) }
        for diagnostic in outputs.diagnostics + machines.flatMap(\.diagnostics) { connection.diagnose(diagnostic) }
    }
}
