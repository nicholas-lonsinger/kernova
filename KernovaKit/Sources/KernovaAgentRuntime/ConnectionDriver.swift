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

/// What a driver does with an effect inside the turn that produced it.
public enum InTurnEffect<Input: Sendable>: Sendable {
    /// Hand it to the effect handler after the turn.
    case deliver
    /// It is done; nothing follows.
    case consumed
    /// Feed this input in the same turn.
    case feed(Input)
}

/// Runs one connection: owns its endpoint, its byte stream and its timer, on one serial queue (§9.5).
///
/// Every turn runs on `queue`: it samples `now`, applies one input to the endpoint under its lock, takes
/// the next `Transmit` when no write is outstanding, drains events and effects, and then — outside the
/// lock — issues the write, re-arms the timer and delivers what it drained. The endpoint is touched
/// only inside those turns.
///
/// A write error stops writing and ends nothing: later transmits are taken and dropped, as a write into a
/// transport the far side shut is, and only the read side's `.ended` ends the transport. Bytes the far
/// side sent before it shut — a RESET(0) above all — are therefore always read.
public final class ConnectionDriver<Endpoint: DrivenEndpoint>: Sendable {
    /// What the driver hands its owner, all on the driver queue.
    public struct Handlers: Sendable {
        /// Runs under the endpoint's lock for each effect, before any is delivered; it must return at once
        /// and never call the driver.
        public var inTurn: @Sendable (Endpoint.Effect) -> InTurnEffect<Endpoint.Input>
        /// Receives each delivered effect; it calls adapters, which return at once.
        public var effect: @Sendable (Endpoint.Effect, ConnectionDriver) -> Void
        /// Receives each event except diagnostics, which the driver logs; it hops to its owner's queue.
        public var event: @Sendable (Endpoint.Event, ConnectionDriver) -> Void

        /// Creates the handlers.
        public init(
            inTurn: @escaping @Sendable (Endpoint.Effect) -> InTurnEffect<Endpoint.Input> = { _ in .deliver },
            effect: @escaping @Sendable (Endpoint.Effect, ConnectionDriver) -> Void = { _, _ in },
            event: @escaping @Sendable (Endpoint.Event, ConnectionDriver) -> Void
        ) {
            self.inTurn = inTurn
            self.effect = effect
            self.event = event
        }
    }

    /// The driver queue: serial, this connection's alone.
    public let queue: DispatchQueue
    /// The connection the endpoint runs.
    public let generation: ConnectionGeneration
    private let stream: any ByteStream
    private let scheduler: any RuntimeScheduler
    private let logger: KernovaLogger
    private let handlers: Handlers
    private let state: Locked<State>

    /// The most one transmit carries: one maximum raw DATA frame and its header.
    static var maxTransmitBytes: Int { WireConstants.maxRawDataPayload + WireConstants.headerByteCount }

    /// A driver for `endpoint` over `stream`; nothing happens until `start()`.
    public init(
        endpoint: Endpoint, stream: any ByteStream, scheduler: any RuntimeScheduler, logger: KernovaLogger,
        handlers: Handlers
    ) {
        generation = endpoint.generation
        queue = DispatchQueue(label: "app.kernova.connection.\(endpoint.generation.rawValue)")
        self.stream = stream
        self.scheduler = scheduler
        self.logger = logger
        self.handlers = handlers
        state = Locked(State(endpoint: endpoint))
    }

    /// Starts the stream's events and runs the first turn, which writes the preamble and Hello.
    public func start() {
        queue.async { [self] in
            stream.start(on: queue) { [self] event in streamEvent(event) }
            turn(.none)
        }
    }

    /// Feeds `input` to the endpoint in a turn of its own.
    public func handle(_ input: Endpoint.Input) {
        queue.async { [self] in turn(.input(input)) }
    }

    /// Closes the connection with `code` in a turn of its own.
    public func close(_ code: ErrorCode) {
        queue.async { [self] in turn(.close(code)) }
    }

    // MARK: Turns

    private enum Step: Sendable {
        case none
        case received(Data)
        case ended
        case timeout(UInt64)
        case writeCompleted(ByteStreamError?)
        case input(Endpoint.Input)
        case close(ErrorCode)
    }

    private enum Writer: Sendable, Equatable {
        case idle
        case inFlight(isFinal: Bool)
        /// A write failed: every later transmit is dropped.
        case broken
    }

    private struct State: Sendable {
        var endpoint: Endpoint
        var writer = Writer.idle
        var armedDeadline: CoreInstant?
        var fire: (any ScheduledFire)?
        var fireToken: UInt64 = 0
        var isShutDown = false
    }

    /// What a turn does outside the lock, in order.
    private struct Outcome: Sendable {
        var write: Transmit?
        var writeFailure: ByteStreamError?
        var cancelledFire: (any ScheduledFire)?
        var arm: (deadline: CoreInstant, token: UInt64)?
        var events: [Endpoint.Event] = []
        var effects: [Endpoint.Effect] = []
        var shutsDown = false
    }

    private func streamEvent(_ event: ByteStreamEvent) {
        switch event {
        case .received(let bytes):
            turn(.received(bytes))
            stream.readMore()
        case .ended:
            turn(.ended)
        }
    }

    private func turn(_ step: Step) {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = scheduler.now
        let outcome = state.withLock { state -> Outcome? in
            guard !state.isShutDown else { return nil }
            var outcome = Outcome()
            apply(step, to: &state, outcome: &outcome, now: now)
            var progressed = true
            while progressed {
                progressed = false
                takeTransmit(&state, outcome: &outcome, now: now)
                while let effect = state.endpoint.pollEffect() {
                    switch handlers.inTurn(effect) {
                    case .deliver:
                        outcome.effects.append(effect)
                    case .consumed:
                        break
                    case .feed(let input):
                        state.endpoint.handle(input, now: now)
                        progressed = true
                    }
                }
                while let event = state.endpoint.pollEvent() {
                    outcome.events.append(event)
                }
            }
            let deadline = state.endpoint.nextDeadline
            if state.endpoint.state == .finished, state.writer != .inFlight(isFinal: true) {
                state.isShutDown = true
                outcome.shutsDown = true
                outcome.cancelledFire = state.fire
                state.fire = nil
                state.armedDeadline = nil
            } else if deadline != state.armedDeadline {
                outcome.cancelledFire = state.fire
                state.fire = nil
                state.armedDeadline = deadline
                state.fireToken += 1
                if let deadline { outcome.arm = (deadline, state.fireToken) }
            }
            return outcome
        }
        guard let outcome else { return }
        perform(outcome)
    }

    private func apply(_ step: Step, to state: inout State, outcome: inout Outcome, now: CoreInstant) {
        switch step {
        case .none:
            break
        case .received(let bytes):
            state.endpoint.receive(bytes, now: now)
        case .ended:
            state.endpoint.transportEnded(now: now)
        case .timeout(let token):
            guard token == state.fireToken else { return }
            state.fire = nil
            state.armedDeadline = nil
            state.endpoint.handleTimeout(now: now)
        case .writeCompleted(let error):
            let wasFinal = state.writer == .inFlight(isFinal: true)
            if let error {
                state.writer = .broken
                outcome.writeFailure = error
            } else {
                state.writer = .idle
            }
            if wasFinal { state.endpoint.transportEnded(now: now) }
        case .input(let input):
            state.endpoint.handle(input, now: now)
        case .close(let code):
            state.endpoint.close(code, now: now)
        }
    }

    /// Takes the next transmit for the stream, or every transmit while the writer is broken.
    private func takeTransmit(_ state: inout State, outcome: inout Outcome, now: CoreInstant) {
        switch state.writer {
        case .idle:
            guard let transmit = state.endpoint.pollTransmit(maxBytes: Self.maxTransmitBytes) else { return }
            state.writer = .inFlight(isFinal: transmit.isFinal)
            outcome.write = transmit
        case .broken:
            while let transmit = state.endpoint.pollTransmit(maxBytes: Self.maxTransmitBytes) {
                if transmit.isFinal { state.endpoint.transportEnded(now: now) }
            }
        case .inFlight:
            break
        }
    }

    private func perform(_ outcome: Outcome) {
        if let transmit = outcome.write {
            stream.write(transmit.chunks) { [self] error in turn(.writeCompleted(error)) }
        }
        if let failure = outcome.writeFailure {
            logger.log(
                .notice,
                "Connection \(generation.rawValue) stopped writing after a write failed (\(String(describing: failure), privacy: .public)); the read side ends it"
            )
        }
        outcome.cancelledFire?.cancel()
        if let arm = outcome.arm {
            let fire = scheduler.schedule(at: arm.deadline, on: queue) { [self] in turn(.timeout(arm.token)) }
            state.withLock { state in
                if state.fireToken == arm.token, !state.isShutDown { state.fire = fire } else { fire.cancel() }
            }
        }
        for event in outcome.events {
            if let diagnostic = Endpoint.diagnostic(in: event) {
                log(diagnostic)
            } else {
                handlers.event(event, self)
            }
        }
        for effect in outcome.effects {
            handlers.effect(effect, self)
        }
        if outcome.shutsDown { stream.shutdown() }
    }

    private func log(_ diagnostic: Diagnostic) {
        let level: KernovaLogLevel =
            switch diagnostic.level {
            case .notice: .notice
            case .error: .error
            }
        switch diagnostic {
        case .remoteViolation(let text), .localFault(let text):
            logger.log(level, "Connection \(generation.rawValue): \(text, privacy: .public)")
        case .suppressed(let count):
            logger.log(level, "Connection \(generation.rawValue) suppressed \(count) diagnostics in the last minute")
        }
    }
}
