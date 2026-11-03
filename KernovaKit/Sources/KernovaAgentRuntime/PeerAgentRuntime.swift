#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// A guest agent's process-wide runtime: the dial schedule, one connection at a time, and the adapters
/// and power ledger that outlive every connection.
///
/// Its state lives on its own serial queue. Each connection runs on a `ConnectionDriver` of its own;
/// adapter reports reach the current one through this queue, and its events come back through it. A
/// connection has ended once its driver has shut its stream down: then the schedule hears of it, though a pull
/// it committed may end later, when its sink reports the publish.
public final class PeerAgentRuntime: Sendable {
    /// Where the runtime sends what the shell acts on, on the runtime's queue.
    public struct Handlers: Sendable {
        /// A connection's event for the shell, but for an `.itemReply`, which answers its item call instead.
        public var event: @Sendable (PeerEvent) -> Void
        /// The agent stops for good; the shell exits with status 0.
        public var stop: @Sendable (StopReason) -> Void

        /// Creates the handlers.
        public init(
            event: @escaping @Sendable (PeerEvent) -> Void = { _ in },
            stop: @escaping @Sendable (StopReason) -> Void
        ) {
            self.event = event
            self.stop = stop
        }
    }

    /// The runtime's queue: serial, every input to the dial schedule runs on it.
    package let queue = DispatchQueue(label: "app.kernova.peer-agent")
    private let claim: PeerClaim
    private let registry: PeerFeatureRegistry
    private let dialer: any TransportDialer
    private let scheduler: any RuntimeScheduler
    private let logger: KernovaLogger
    private let handlers: Handlers
    private let receiverPolicy: ReceiverPolicy
    /// The process's power ledger: written on the driver queue for each effect carried out, and on the
    /// adapter's thread for each report, before the report hops to this queue — so a configuration built
    /// here after a report always carries it.
    private let ledger = Locked(PowerLedger())
    private let state: Locked<State>

    private struct State: Sendable {
        var agent: PeerAgent
        var driver: ConnectionDriver<PeerEndpoint>?
        /// Nil while the peer has no session to serve, and the schedule is parked.
        var peerState: PeerSessionState?
        var power: Availability<PowerOffer>
        var update: Availability<UpdateOffer>
        var timer = TimerSlot()
        var closeCompletions: [@Sendable () -> Void] = []
        var items = ItemRequests<ConnectionGeneration>()
    }

    /// A runtime for a peer claiming `claim`, whose `instanceID` it replaces with 16 bytes it draws once.
    /// With no `state` it dials nothing until `setPeerState(_:)` gives it one.
    public init(
        claim: PeerClaim, state: PeerSessionState?, registry: PeerFeatureRegistry, dialer: any TransportDialer,
        scheduler: any RuntimeScheduler, logger: KernovaLogger, receiverPolicy: ReceiverPolicy = .production,
        handlers: Handlers
    ) {
        var claim = claim
        var generator = SystemRandomNumberGenerator()
        claim.instanceID = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        self.claim = claim
        self.registry = registry
        self.dialer = dialer
        self.scheduler = scheduler
        self.logger = logger
        self.receiverPolicy = receiverPolicy
        self.handlers = handlers
        let unregistered = "no adapter registered"
        self.state = Locked(
            State(
                agent: PeerAgent(now: scheduler.now, parked: state == nil), peerState: state,
                power: registry.power == nil
                    ? .absent(.notImplemented, debugDetail: unregistered)
                    : .absent(.unspecified, debugDetail: "not yet reported"),
                update: registry.update == nil
                    ? .absent(.notImplemented, debugDetail: unregistered)
                    : .absent(.unspecified, debugDetail: "not yet reported")))
    }

    /// Starts the adapters and dials.
    public func start() {
        queue.async { [self] in
            registry.power?.start(reporter: PowerReporter { [self] input in report(.power(input)) })
            registry.update?.start(reporter: UpdateReporter { [self] input in report(.update(input)) })
            registry.logs?.recordsAvailable.withLock { hook in
                hook = { [self] in
                    queue.async { [self] in state.withLock { $0.driver }?.handle(.logs(.recordsAvailable)) }
                }
            }
            step { _, _ in }
        }
    }

    /// The session's state changed; nil when the peer has no session to serve.
    ///
    /// A connection serves one session for its life: a session peer's new session, or none, closes the
    /// connection with `SHUTTING_DOWN`. With a session the runtime dials at once, as soon as that
    /// connection has ended; with none it dials nothing until a later call gives it one.
    public func setPeerState(_ peerState: PeerSessionState?) {
        queue.async { [self] in
            let (previous, driver) = state.withLock { state in
                defer { state.peerState = peerState }
                return (state.peerState, state.driver)
            }
            if let peerState, let previous,
                claim.role != .sessionPeer || previous.sessionID == peerState.sessionID
            {
                driver?.handle(.peerState(peerState))
                return
            }
            step { agent, now in agent.park(now: now) }
            driver?.close(.shuttingDown)
            if peerState != nil { step { agent, now in agent.unpark(now: now) } }
        }
    }

    /// Stops dialing and closes the connection with `SHUTTING_DOWN`. `completion` runs on the runtime's
    /// queue once the connection has ended — its stream shut down, whether or not a pull it committed has
    /// ended — or at once when there is none.
    public func close(_ completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            step { agent, now in agent.shutDown(now: now) }
            let driver = state.withLock { state in
                if state.driver != nil { state.closeCompletions.append(completion) }
                return state.driver
            }
            if let driver { driver.close(.shuttingDown) } else { completion() }
        }
    }

    // MARK: Items

    /// Offers `offer` on `feature` — CLIPBOARD, withdrawing the previous clipboard offer, or DRAG — to the host,
    /// and calls `completion` once, on the runtime's queue, with nil once it opened, whose `.items` events then
    /// follow, or why it did not. Each item call's answer, like each event, reaches the runtime's queue in the
    /// order the connection emitted them; with no connection, or once it ends, a call is answered as ended.
    public func offerItems(
        _ offer: ItemOffer, feature: FeatureID, _ completion: @escaping @Sendable (WireError?) -> Void
    ) {
        awaitReply(
            { .offer($0, offer, feature: feature) }, { if case .offered(let refusal) = $0 { refusal } else { nil } },
            unanswered: Self.connectionEnded, completion)
    }

    /// Withdraws this side's offer of `token`; its `.offerEnded` follows.
    public func withdrawOffer(_ token: Data) {
        send(.withdraw(token: token))
    }

    /// Releases the host's offer of `token`: this side pulls nothing more of it.
    public func releaseOffer(_ token: Data) {
        send(.release(token: token))
    }

    /// Pulls one representation of the host's open offer as `order` says, and calls `completion` once with the
    /// pull's id, whose one `.pullEnded` follows, or why it was not opened.
    public func pullItem(
        _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
    ) {
        awaitReply(
            { .pull($0, order) }, { if case .pulled(let result) = $0 { result } else { nil } },
            unanswered: .failure(Self.connectionEnded), completion)
    }

    /// Cancels a pull this side opened; its `.pullEnded` follows.
    public func cancelPull(_ id: ItemPullID) {
        send(.cancel(id))
    }

    /// Calls `completion` once with item `item` of the host's open offer of `token`, decoded; nil when no such
    /// item is held.
    public func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        awaitReply(
            { .read($0, token: token, item: item) }, { if case .read(let read) = $0 { .some(read) } else { nil } },
            unanswered: nil, completion)
    }

    /// Answers the host's take `id` of this side's drag.
    public func answerDragTake(_ id: DragTakeID, _ answer: DragTakeAnswer) {
        queue.async { [self] in state.withLock { $0.driver }?.handle(.dragTake(id, answer)) }
    }

    private static var connectionEnded: WireError { ItemRequests<ConnectionGeneration>.connectionEnded }

    /// Sends the current connection the command `command` builds around a fresh request id, and calls
    /// `completion` once with what `read` reads from its reply — or with `unanswered`, at once with no
    /// connection, or later when it ends without replying.
    private func awaitReply<Answer: Sendable>(
        _ command: @escaping @Sendable (ItemRequestID) -> ItemCommand,
        _ read: @escaping @Sendable (ItemReply) -> Answer?, unanswered: Answer,
        _ completion: @escaping @Sendable (Answer) -> Void
    ) {
        let answer = ItemRequests<ConnectionGeneration>.answering(read, unanswered: unanswered, completion)
        queue.async { [self] in
            let sent = state.withLock { state -> (ConnectionDriver<PeerEndpoint>, ItemCommand)? in
                guard let driver = state.driver else { return nil }
                return (driver, state.items.add(driver.generation, command, feature: nil, answer))
            }
            guard let (driver, command) = sent else { return answer(nil) }
            driver.handle(.itemCommand(command))
        }
    }

    private func send(_ command: ItemCommand) {
        queue.async { [self] in state.withLock { $0.driver }?.handle(.itemCommand(command)) }
    }

    // MARK: The dial schedule

    /// Runs one input on the dial schedule — unless it is a fire that is no longer armed — then its
    /// effects, and re-arms the timer.
    private func step(firing token: UInt64? = nil, _ body: (inout PeerAgent, CoreInstant) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = scheduler.now
        let effects = state.withLock { state -> [AgentEffect] in
            if let token, !state.timer.take(token) { return [] }
            body(&state.agent, now)
            var effects: [AgentEffect] = []
            while let effect = state.agent.pollEffect() { effects.append(effect) }
            state.timer.arm(state.agent.nextDeadline, scheduler: scheduler, queue: queue) { [self] token in
                step(firing: token) { agent, now in agent.handleTimeout(now: now) }
            }
            return effects
        }
        for effect in effects {
            switch effect {
            case .dial: dialer.dial { [self] result in queue.async { [self] in dialed(result) } }
            case .stop(let reason): handlers.stop(reason)
            }
        }
    }

    private func dialed(_ result: Result<any ByteStream, DialFailure>) {
        switch result {
        case .failure(let failure):
            step { agent, now in agent.dialFailed(failure, now: now) }
        case .success(let stream):
            var generation: ConnectionGeneration?
            step { agent, now in generation = agent.dialSucceeded(now: now) }
            guard let generation else { return stream.shutdown() }
            let ledger = ledger.withLock { $0 }
            var configuration = state.withLock { state in
                // The schedule connects nothing while parked, which is exactly while there is no state.
                PeerConfiguration(
                    claim: claim, state: state.peerState ?? PeerSessionState(), power: state.power,
                    logs: registry.logs == nil
                        ? .absent(.notImplemented, debugDetail: "no log forwarding") : .available(NoParams()),
                    update: state.update)
            }
            configuration.powerLedger = ledger
            configuration.receiverPolicy = receiverPolicy
            configuration.items = ItemAdapters.availability(registry.items)
            let driver = ConnectionDriver(
                endpoint: PeerEndpoint(configuration, generation: generation, now: scheduler.now), stream: stream,
                scheduler: scheduler, logger: logger, handlers: driverHandlers(generation))
            state.withLock { $0.driver = driver }
            driver.start()
        }
    }

    // MARK: The connection

    private func driverHandlers(_ generation: ConnectionGeneration) -> ConnectionDriver<PeerEndpoint>.Handlers {
        let logs = registry.logs
        let itemConnection = ItemConnection(role: claim.role)
        return ConnectionDriver<PeerEndpoint>.Handlers(
            inTurn: { effect in
                guard case .logs(let effect) = effect, let logs else { return .deliver }
                switch effect {
                case .mode(let mode):
                    logs.ring.withLock { $0.setMode(mode) }
                    return .consumed
                case .ready:
                    guard let batch = logs.ring.withLock({ $0.takeBatch() }) else { return .consumed }
                    return .feed(.logs(.batch(batch)))
                }
            },
            effect: { [registry, ledger] effect, driver in
                switch effect {
                case .power(let effect):
                    ledger.withLock { $0.record(effect) }
                    switch effect {
                    case .perform(let id, let action): registry.power?.perform(id, action)
                    case .cancel(let id): registry.power?.cancel(id)
                    }
                case .update(.payload(let id, let bytes)): registry.update?.write(id, bytes)
                case .update(.complete(let id, let manifest)): registry.update?.complete(id, manifest)
                case .update(.abort(let id)): registry.update?.abort(id)
                case .update(.recordRejected(let hash)): registry.update?.recordRejected(hash)
                case .update(.clearRejected): registry.update?.clearRejected()
                case .itemSource(let effect):
                    registry.items?.source.handle(
                        effect, reporter: ItemSourceReporter(itemConnection) { driver.handle(.items(.source($0))) })
                case .itemSink(let effect):
                    registry.items?.sink.handle(
                        effect, reporter: ItemSinkReporter(itemConnection) { driver.handle(.items(.sink($0))) })
                case .logs: break
                }
            },
            event: { [self] event, _ in
                queue.async { [self] in connectionEvent(event, generation) }
            },
            ended: { [self] closure, _ in
                queue.async { [self] in connectionEnded(generation, closure) }
            })
    }

    private func connectionEvent(_ event: PeerEvent, _ generation: ConnectionGeneration) {
        switch event {
        case .policyReceived:
            step { agent, now in agent.policyReceived(generation, now: now) }
        case .itemReply(let id, let reply):
            state.withLock { $0.items.take(id, from: generation) }?.answer(reply)
            return
        default:
            break
        }
        handlers.event(event)
    }

    /// The connection has ended: each item call it did not answer is answered as ended, the schedule hears of
    /// it, and `close` completes.
    private func connectionEnded(_ generation: ConnectionGeneration, _ closure: ConnectionClosure) {
        for pending in state.withLock({ $0.items.takeAll(of: generation) }) { pending.answer(nil) }
        let completions = state.withLock { state -> [@Sendable () -> Void] in
            guard state.driver?.generation == generation else { return [] }
            state.driver = nil
            defer { state.closeCompletions.removeAll() }
            return state.closeCompletions
        }
        step { agent, now in agent.connectionEnded(generation, closure, now: now) }
        for completion in completions { completion() }
    }

    /// An adapter's report: remembered for the next connection's configuration and ledger, and fed to the
    /// current one.
    private func report(_ input: PeerInput) {
        if case .power(let report) = input { ledger.withLock { $0.record(report) } }
        queue.async { [self] in
            let driver = state.withLock { state in
                switch input {
                case .power(.availability(let availability)): state.power = availability
                case .update(.availability(let availability)): state.update = availability
                case .power, .update, .logs, .items, .dragTake, .itemCommand, .peerState: break
                }
                return state.driver
            }
            driver?.handle(input)
        }
    }
}
