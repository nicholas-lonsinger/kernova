#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a peer's power adapter reports.
public enum PowerInput: Sendable, Equatable {
    /// What the adapter can do now.
    case availability(Availability<PowerOffer>)
    /// The OS took the request.
    case accepted(PowerRequestID)
    /// The OS refused it; nothing was done.
    case refused(PowerRequestID, WireError)
    /// The OS confirms a cancelled request did not start.
    case cancelled(PowerRequestID)
    /// Apps are being asked to quit.
    case askingApps(PowerRequestID)
    /// These apps are holding it up.
    case waitingOnApps(PowerRequestID, [AppValue])
    /// The OS is going down.
    case handedOff(PowerRequestID)
    /// These apps stopped it.
    case blocked(PowerRequestID, [AppValue])
    /// A user in the guest cancelled it.
    case cancelledInGuest(PowerRequestID)
    /// The OS gave up after accepting.
    case failed(PowerRequestID, WireError)
}

/// What a peer's power machine asks its adapter to do.
public enum PowerEffect: Sendable, Equatable {
    /// Ask the OS to perform `action`.
    case perform(PowerRequestID, PowerAction)
    /// Cancel the request if the OS has not started it.
    case cancel(PowerRequestID)
}

/// A progress stage after acceptance.
public enum PowerStage: Sendable, Equatable {
    /// Apps are being asked to quit.
    case askingApps
    /// Apps are holding it up.
    case waitingOnApps
}

/// How an accepted power request ended.
public enum PowerFinish: Sendable, Equatable {
    /// The OS is going down.
    case handedOff
    /// These apps stopped it.
    case blocked([AppValue])
    /// A user in the guest cancelled it.
    case cancelledInGuest
    /// The OS gave up after accepting, or the outcome made no sense.
    case failed(WireError)
}

/// The host's view of one power request (§6.3).
public enum PowerRequestResult: Sendable, Equatable {
    /// The peer's OS took it; no other provider may be asked.
    case accepted
    /// Progress after acceptance.
    case progress(PowerStage, [AppValue])
    /// Nothing happened, known for certain; routing may ask the next provider.
    case refused(WireError)
    /// The host cannot know what happened; routing ends.
    case indeterminate
    /// It ended after acceptance.
    case finished(PowerFinish)
    /// The connection ended after acceptance (usually the guest going down).
    case lostAfterAcceptance
}

// MARK: - Peer

/// The peer process's record of the one power request its adapter holds
/// (§6.2): from the `.perform` effect until the adapter's terminal report, in
/// whatever order the reports come. It outlives connections, so the runtime
/// keeps one per process, as it keeps the `LogRing`: it records every power
/// effect it carries out and every report the adapter makes, and hands the
/// ledger to each new endpoint in `PeerConfiguration`. `PowerResponder` keeps
/// its own copy by the same two calls, so one request at a time holds at
/// process scope whatever the adapter does.
public struct PowerLedger: Sendable, Equatable {
    /// The request the adapter holds; nil when it holds none.
    public private(set) var held: PowerRequestID?

    /// A ledger for a process whose adapter holds nothing.
    public init() {}

    /// Records an effect the runtime carries out.
    public mutating func record(_ effect: PowerEffect) {
        if case .perform(let id, _) = effect { held = id }
    }

    /// Records the adapter's report: a terminal one for the held request releases it.
    public mutating func record(_ input: PowerInput) {
        guard let id = input.requestID, id == held, input.isTerminal else { return }
        held = nil
    }
}

/// The peer's power machine (§6.2): one request at a time on this peer.
public struct PowerResponder: FeatureMachine {
    /// POWER.
    public static let feature = FeatureID.power

    private enum Phase: Sendable, Equatable {
        case asked, cancelling, accepted
    }

    /// The request this connection opened, kept until the adapter's terminal
    /// report even after its stream closes.
    private struct Request: Sendable {
        var stream: StreamID
        var id: PowerRequestID
        var phase: Phase
        var deadline: JudgedDeadline?
        var streamOpen = true
        /// The one progress message not yet sendable, a newer one replacing it.
        var pending: Data?
    }

    private var availability: Availability<PowerOffer>
    private var ledger: PowerLedger
    private var request: Request?
    private let generation: ConnectionGeneration
    private(set) var outbox: [PeerEffect] = []
    private(set) var diagnostics: [Diagnostic] = []

    /// A responder over the adapter's last reported availability and the
    /// process's ledger, which may hold a request from an earlier connection.
    public init(availability: Availability<PowerOffer>, ledger: PowerLedger, generation: ConnectionGeneration) {
        self.availability = availability
        self.ledger = ledger
        self.generation = generation
    }

    /// The `PowerCapability` advert, or the adapter's absence.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { $0.encoded })
    }

    /// The acceptance deadline of a request still asked.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? {
        request?.deadline?.wake(clock)
    }

    mutating func takeOutputs() -> (effects: [PeerEffect], diagnostics: [Diagnostic]) {
        defer {
            outbox.removeAll()
            diagnostics.removeAll()
        }
        return (outbox, diagnostics)
    }

    /// Handles a stream event for POWER_REQUEST.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .opened(let stream, let body):
            opened(stream, body: body, connection: &connection)
        case .writable(let stream):
            if request?.stream == stream { flushPending(&connection) }
        case .streamClosed(let stream, _):
            streamClosed(stream)
        case .deadline:
            guard var current = request, current.phase == .asked, var deadline = current.deadline else { break }
            let fires = deadline.evaluate(connection.clock)
            current.deadline = deadline
            if fires {
                current.phase = .cancelling
                current.deadline = nil
                outbox.append(.power(.cancel(current.id)))
            }
            request = current
        case .sessionEstablished, .usabilityChanged, .policyChanged, .message, .data, .remoteEnded:
            break
        }
    }

    /// Handles the adapter's report.
    public mutating func handle(input: PowerInput, connection: inout Connection, now: CoreInstant) {
        if case .availability(let availability) = input {
            self.availability = availability
            return
        }
        guard let id = input.requestID else { return }
        let held = ledger.held
        ledger.record(input)
        guard var current = request, current.id == id else {
            // An earlier connection's request ends in the ledger alone; nothing else here knows of it.
            if id != held, id.generation == generation {
                diagnostics.append(.localFault("power adapter report for an unknown request: \(input)"))
            }
            return
        }
        switch (current.phase, input) {
        case (.asked, .accepted), (.cancelling, .accepted):
            current.phase = .accepted
            current.deadline = nil
            request = current
            var progress = Kernova_V2_PowerProgress()
            progress.stage = .accepted
            sendProgress(progress.encoded, connection: &connection)
        case (.asked, .refused(_, let error)), (.cancelling, .refused(_, let error)):
            finish(.refused, error: error, connection: &connection)
        case (.cancelling, .cancelled):
            finish(.refused, error: WireError(.timeout), connection: &connection)
        case (.accepted, .askingApps):
            var progress = Kernova_V2_PowerProgress()
            progress.stage = .askingApps
            sendProgress(progress.encoded, connection: &connection)
        case (.accepted, .waitingOnApps(_, let apps)):
            var progress = Kernova_V2_PowerProgress()
            progress.stage = .waitingOnApps
            progress.apps = AppValue.wire(apps)
            sendProgress(progress.encoded, connection: &connection)
        case (.accepted, .handedOff):
            finish(.handedOff, connection: &connection)
        case (.accepted, .blocked(_, let apps)):
            finish(.blocked, apps: apps, connection: &connection)
        case (.accepted, .cancelledInGuest):
            finish(.cancelledInGuest, connection: &connection)
        case (.accepted, .failed(_, let error)):
            finish(.failed, error: error, connection: &connection)
        default:
            diagnostics.append(.localFault("power adapter reported \(input) out of order"))
            guard ledger.held == nil else { return }
            // The adapter no longer holds the request, so neither does this
            // machine, and the host cannot know what happened.
            request = nil
            if current.streamOpen, connection.canReset(current.stream) {
                connection.reset(
                    current.stream, WireError(.internal, debugDetail: "the power adapter reported out of order"))
            }
        }
    }

    private mutating func opened(_ stream: StreamID, body: Data, connection: inout Connection) {
        let powerRequest = (try? Kernova_V2_PowerRequest(serializedBytes: body)) ?? Kernova_V2_PowerRequest()
        let offered = availability.params?.actions ?? []
        guard offered.contains(powerRequest.action), powerRequest.action != .unspecified else {
            return refuse(stream, .powerActionUnsupported, connection: &connection)
        }
        guard ledger.held == nil else { return refuse(stream, .powerInProgress, connection: &connection) }
        let id = PowerRequestID(generation: generation, rawValue: UInt64(stream.rawValue))
        var current = Request(stream: stream, id: id, phase: .asked)
        if powerRequest.acceptanceDeadlineMs > 0 {
            current.deadline = connection.judgedDeadline(
                after: .milliseconds(Int64(powerRequest.acceptanceDeadlineMs)))
        }
        request = current
        let effect = PowerEffect.perform(id, powerRequest.action)
        ledger.record(effect)
        outbox.append(.power(effect))
    }

    private func refuse(_ stream: StreamID, _ code: ErrorCode, connection: inout Connection) {
        guard connection.canQueue(on: stream) else { return }
        var outcome = Kernova_V2_PowerOutcome()
        outcome.kind = .refused
        outcome.error = WireError(code).proto
        connection.end(stream, body: outcome.encoded)
    }

    /// The stream closed: the request stays until the adapter's terminal report,
    /// sending nothing more; an asked one is cancelled.
    private mutating func streamClosed(_ stream: StreamID) {
        guard var current = request, current.stream == stream else { return }
        current.streamOpen = false
        current.pending = nil
        if current.phase == .asked {
            current.phase = .cancelling
            current.deadline = nil
            outbox.append(.power(.cancel(current.id)))
        }
        request = current
    }

    private mutating func sendProgress(_ message: Data, connection: inout Connection) {
        guard var current = request, current.streamOpen, connection.canQueue(on: current.stream) else { return }
        if current.pending == nil, connection.canSendMessage(message.count, on: current.stream) {
            connection.send(message: message, on: current.stream)
        } else {
            current.pending = message
        }
        request = current
    }

    private mutating func flushPending(_ connection: inout Connection) {
        guard var current = request, let pending = current.pending,
            connection.canSendMessage(pending.count, on: current.stream)
        else { return }
        connection.send(message: pending, on: current.stream)
        current.pending = nil
        request = current
    }

    private mutating func finish(
        _ kind: Kernova_V2_PowerOutcome.Kind, error: WireError? = nil, apps: [AppValue] = [],
        connection: inout Connection
    ) {
        guard let current = request else { return }
        request = nil
        guard current.streamOpen, connection.canQueue(on: current.stream) else { return }
        var outcome = Kernova_V2_PowerOutcome()
        outcome.kind = kind
        if let error { outcome.error = error.proto }
        outcome.apps = AppValue.wire(apps)
        connection.end(current.stream, body: outcome.encoded)
    }
}

extension PowerInput {
    var requestID: PowerRequestID? {
        switch self {
        case .availability: nil
        case .accepted(let id), .refused(let id, _), .cancelled(let id), .askingApps(let id),
            .waitingOnApps(let id, _), .handedOff(let id), .blocked(let id, _), .cancelledInGuest(let id),
            .failed(let id, _):
            id
        }
    }

    /// The adapter no longer holds the request after this report.
    var isTerminal: Bool {
        switch self {
        case .refused, .cancelled, .handedOff, .blocked, .cancelledInGuest, .failed: true
        case .availability, .accepted, .askingApps, .waitingOnApps: false
        }
    }
}

// MARK: - Host

/// The host's power machine (§6.3): one entry per open request stream.
public struct PowerRequester: FeatureMachine {
    /// POWER.
    public static let feature = FeatureID.power
    /// The acceptance deadline the host sends.
    static let peerDeadline: UInt32 = 10_000
    /// How long the host waits for ACCEPTED or END.
    static let hostWait = CoreDuration.seconds(15)

    private enum Phase: Sendable, Equatable {
        case waiting, accepted
    }

    private struct Entry: Sendable {
        var id: PowerRequestID
        var stream: StreamID
        var phase: Phase
        var deadline: JudgedDeadline?
    }

    private var entries: [Entry] = []
    private let generation: ConnectionGeneration
    private(set) var outbox: [HostEvent] = []
    private(set) var diagnostics: [Diagnostic] = []

    /// A requester for one connection.
    public init(generation: ConnectionGeneration) {
        self.generation = generation
    }

    /// The host advertises POWER available with empty params.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: .available(Data()))
    }

    /// The soonest acceptance wait of a request still waiting.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? {
        entries.compactMap { $0.deadline?.wake(clock) }.min()
    }

    mutating func takeOutputs() -> (events: [HostEvent], diagnostics: [Diagnostic]) {
        defer {
            outbox.removeAll()
            diagnostics.removeAll()
        }
        return (outbox, diagnostics)
    }

    /// Starts a request: opens POWER_REQUEST and ends it at once.
    public mutating func request(_ id: PowerRequestID, _ action: PowerAction, connection: inout Connection) {
        guard id.generation == generation else { return }
        guard !entries.contains(where: { $0.id == id }) else {
            diagnostics.append(.localFault("a second power request with one id"))
            return
        }
        if let refusal = connection.openRefusal(.powerRequest) {
            outbox.append(.power(id, .refused(refusal)))
            return
        }
        var body = Kernova_V2_PowerRequest()
        body.action = action
        body.acceptanceDeadlineMs = Self.peerDeadline
        let stream = connection.open(.powerRequest, body: body.encoded)
        guard connection.canQueue(on: stream) else { return }
        connection.end(stream, body: Data())
        entries.append(
            Entry(id: id, stream: stream, phase: .waiting, deadline: connection.judgedDeadline(after: Self.hostWait)))
    }

    /// The hub cancels a request; only a waiting one can be (§6.3).
    public mutating func cancel(_ id: PowerRequestID, connection: inout Connection) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].phase == .waiting else {
            diagnostics.append(.localFault("cancel of an accepted power request"))
            return
        }
        conclude(index, .indeterminate, reset: .cancelled, connection: &connection)
    }

    /// Handles a stream event for POWER_REQUEST.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .message(let stream, let payload):
            guard let index = entries.firstIndex(where: { $0.stream == stream }) else { return }
            progress(index, payload, connection: &connection)
        case .remoteEnded(let stream, let body):
            guard let index = entries.firstIndex(where: { $0.stream == stream }) else { return }
            ended(index, body)
        case .streamClosed(let stream, let closure):
            guard let index = entries.firstIndex(where: { $0.stream == stream }) else { return }
            closed(index, closure)
        case .deadline:
            for index in entries.indices.reversed() {
                guard entries[index].phase == .waiting, var deadline = entries[index].deadline else { continue }
                let fires = deadline.evaluate(connection.clock)
                entries[index].deadline = deadline
                if fires { conclude(index, .indeterminate, reset: .timeout, connection: &connection) }
            }
        case .sessionEstablished, .usabilityChanged, .policyChanged, .opened, .data, .writable:
            break
        }
    }

    private mutating func progress(_ index: Int, _ payload: Data, connection: inout Connection) {
        guard let message = try? Kernova_V2_PowerProgress(serializedBytes: payload) else {
            return conclude(index, .indeterminate, reset: .malformedMessage, connection: &connection)
        }
        let id = entries[index].id
        switch (entries[index].phase, message.stage) {
        case (.waiting, .accepted):
            entries[index].phase = .accepted
            entries[index].deadline = nil
            outbox.append(.power(id, .accepted))
        case (.waiting, .askingApps), (.waiting, .waitingOnApps), (.accepted, .accepted):
            conclude(index, .indeterminate, reset: .streamProtocolError, connection: &connection)
        case (.accepted, .askingApps):
            outbox.append(.power(id, .progress(.askingApps, [])))
        case (.accepted, .waitingOnApps):
            outbox.append(.power(id, .progress(.waitingOnApps, AppValue.received(message.apps))))
        case (_, .unspecified), (_, .UNRECOGNIZED):
            break
        }
    }

    private mutating func ended(_ index: Int, _ body: Data) {
        let outcome = (try? Kernova_V2_PowerOutcome(serializedBytes: body)) ?? Kernova_V2_PowerOutcome()
        let error = outcome.hasError ? WireError(received: outcome.error) : WireError(.unspecified)
        let result: PowerRequestResult
        switch (entries[index].phase, outcome.kind) {
        case (.waiting, .refused):
            result = error.code == .powerInProgress ? .indeterminate : .refused(error)
        case (.waiting, _):
            result = .indeterminate
        case (.accepted, .handedOff):
            result = .finished(.handedOff)
        case (.accepted, .blocked):
            result = .finished(.blocked(AppValue.received(outcome.apps)))
        case (.accepted, .cancelledInGuest):
            result = .finished(.cancelledInGuest)
        case (.accepted, _):
            result = .finished(.failed(error))
        }
        outbox.append(.power(entries[index].id, result))
        entries.remove(at: index)
    }

    private mutating func closed(_ index: Int, _ closure: StreamClosure) {
        let result: PowerRequestResult
        switch (entries[index].phase, closure) {
        case (.waiting, .resetByPeer(let error))
        where [.unsupportedKind, .featureUnavailable, .tooManyStreams, .malformedMessage].contains(error.code):
            result = .refused(error)
        case (.accepted, .connectionClosedLocally), (.accepted, .connectionClosedByPeer),
            (.accepted, .connectionLost):
            result = .lostAfterAcceptance
        default:
            result = .indeterminate
        }
        outbox.append(.power(entries[index].id, result))
        entries.remove(at: index)
    }

    private mutating func conclude(
        _ index: Int, _ result: PowerRequestResult, reset code: ErrorCode, connection: inout Connection
    ) {
        let entry = entries.remove(at: index)
        outbox.append(.power(entry.id, result))
        if connection.canReset(entry.stream) {
            connection.reset(entry.stream, WireError(code))
        }
    }
}
