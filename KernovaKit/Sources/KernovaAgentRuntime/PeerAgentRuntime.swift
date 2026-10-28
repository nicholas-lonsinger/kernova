#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaWire
import KernovaLogging
import KernovaSynchronization

/// A guest agent's process-wide runtime: the dial schedule, one connection at a time, and the adapters
/// that outlive every connection (§9.5).
///
/// Its state lives on its own serial queue. Each connection runs on a `ConnectionDriver` of its own;
/// adapter reports reach the current one through this queue, and its events come back through it.
public final class PeerAgentRuntime: Sendable {
    /// Where the runtime sends what the shell acts on, on the runtime's queue.
    public struct Handlers: Sendable {
        /// A connection's event for the shell's UI.
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

    private let queue = DispatchQueue(label: "app.kernova.peer-agent")
    private let claim: PeerClaim
    private let registry: PeerFeatureRegistry
    private let dialer: any TransportDialer
    private let scheduler: any RuntimeScheduler
    private let logger: KernovaLogger
    private let handlers: Handlers
    private let receiverPolicy: ReceiverPolicy
    private let state: Locked<State>

    private struct State: Sendable {
        var agent: PeerAgent
        var driver: ConnectionDriver<PeerEndpoint>?
        var peerState: PeerSessionState
        var power: Availability<PowerOffer>
        var update: Availability<UpdateOffer>
        var fire: (any ScheduledFire)?
        var armedDeadline: CoreInstant?
        var fireToken: UInt64 = 0
        var isStopped = false
        var closeCompletion: (@Sendable () -> Void)?
    }

    /// A runtime for a peer claiming `claim`, whose `instanceID` it replaces with 16 bytes it draws once.
    public init(
        claim: PeerClaim, state: PeerSessionState, registry: PeerFeatureRegistry, dialer: any TransportDialer,
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
        let unreported = Availability<PowerOffer>.absent(.notImplemented, debugDetail: "no adapter registered")
        self.state = Locked(
            State(
                agent: PeerAgent(now: scheduler.now), peerState: state,
                power: registry.power == nil ? unreported : .absent(.unspecified, debugDetail: "not yet reported"),
                update: registry.update == nil
                    ? .absent(.notImplemented, debugDetail: "no adapter registered")
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

    /// The session's state changed.
    public func setPeerState(_ peerState: PeerSessionState) {
        queue.async { [self] in
            let driver = state.withLock { state in
                state.peerState = peerState
                return state.driver
            }
            driver?.handle(.peerState(peerState))
        }
    }

    /// Stops dialing and closes the connection with `SHUTTING_DOWN`; `completion` runs on the runtime's
    /// queue once the connection has ended, or at once when there is none.
    public func close(_ completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            let driver = state.withLock { state -> ConnectionDriver<PeerEndpoint>? in
                state.isStopped = true
                state.fireToken += 1
                state.fire?.cancel()
                state.fire = nil
                if state.driver != nil { state.closeCompletion = completion }
                return state.driver
            }
            if let driver { driver.close(.shuttingDown) } else { completion() }
        }
    }

    // MARK: The dial schedule

    /// Runs one input on the dial schedule, then its effects and timer.
    private func step(_ body: (inout PeerAgent, CoreInstant) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = scheduler.now
        var effects: [AgentEffect] = []
        var arm: (deadline: CoreInstant, token: UInt64)?
        var cancelled: (any ScheduledFire)?
        state.withLock { state in
            body(&state.agent, now)
            while let effect = state.agent.pollEffect() { effects.append(effect) }
            let deadline = state.isStopped ? nil : state.agent.nextDeadline
            guard deadline != state.armedDeadline else { return }
            cancelled = state.fire
            state.fire = nil
            state.armedDeadline = deadline
            state.fireToken += 1
            if let deadline { arm = (deadline, state.fireToken) }
        }
        cancelled?.cancel()
        if let arm {
            let fire = scheduler.schedule(at: arm.deadline, on: queue) { [self] in
                guard state.withLock({ $0.fireToken == arm.token }) else { return }
                step { agent, now in
                    agent.handleTimeout(now: now)
                }
            }
            state.withLock { state in
                if state.fireToken == arm.token { state.fire = fire } else { fire.cancel() }
            }
        }
        for effect in effects {
            switch effect {
            case .dial:
                guard !state.withLock(\.isStopped) else { continue }
                dialer.dial { [self] result in queue.async { [self] in dialed(result) } }
            case .stop(let reason):
                state.withLock { $0.isStopped = true }
                handlers.stop(reason)
            }
        }
    }

    private func dialed(_ result: Result<any ByteStream, DialFailure>) {
        switch result {
        case .failure(let failure):
            step { agent, now in agent.dialFailed(failure, now: now) }
        case .success(let stream):
            guard !state.withLock(\.isStopped) else { return stream.shutdown() }
            var generation = ConnectionGeneration(rawValue: 0)
            step { agent, now in generation = agent.dialSucceeded(now: now) }
            var configuration = state.withLock { state in
                PeerConfiguration(
                    claim: claim, state: state.peerState, power: state.power,
                    logs: registry.logs == nil
                        ? .absent(.notImplemented, debugDetail: "no log forwarding") : .available(NoParams()),
                    update: state.update)
            }
            configuration.receiverPolicy = receiverPolicy
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
            effect: { [registry] effect, _ in
                switch effect {
                case .power(.perform(let id, let action)): registry.power?.perform(id, action)
                case .power(.cancel(let id)): registry.power?.cancel(id)
                case .update(.payload(let id, let bytes)): registry.update?.write(id, bytes)
                case .update(.complete(let id, let manifest)): registry.update?.complete(id, manifest)
                case .update(.abort(let id)): registry.update?.abort(id)
                case .update(.recordRejected(let hash)): registry.update?.recordRejected(hash)
                case .update(.clearRejected): registry.update?.clearRejected()
                case .logs: break
                }
            },
            event: { [self] event, _ in
                queue.async { [self] in connectionEvent(event, generation) }
            })
    }

    private func connectionEvent(_ event: PeerEvent, _ generation: ConnectionGeneration) {
        switch event {
        case .policyReceived:
            step { agent, now in agent.policyReceived(generation, now: now) }
        case .closed(let closure):
            let completion = state.withLock { state -> (@Sendable () -> Void)? in
                guard state.driver?.generation == generation else { return nil }
                state.driver = nil
                defer { state.closeCompletion = nil }
                return state.closeCompletion
            }
            step { agent, now in agent.connectionEnded(generation, closure, now: now) }
            completion?()
        case .established, .hostLiveness, .updateAvailable, .diagnostic:
            break
        }
        handlers.event(event)
    }

    /// An adapter's report: remembered for the next connection's configuration, and fed to the current one.
    private func report(_ input: PeerInput) {
        queue.async { [self] in
            let driver = state.withLock { state in
                switch input {
                case .power(.availability(let availability)): state.power = availability
                case .update(.availability(let availability)): state.update = availability
                case .power, .update, .logs, .peerState: break
                }
                return state.driver
            }
            driver?.handle(input)
        }
    }
}
