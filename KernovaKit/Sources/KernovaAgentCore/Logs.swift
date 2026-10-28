#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What the peer's log sink and runtime report.
public enum LogInput: Sendable, Equatable {
    /// A record was appended into an empty ring.
    case recordsAvailable
    /// The batch the runtime took from the ring after `.ready`.
    case batch(LogBatchValue)
}

/// What the peer's log forwarder asks the runtime to do.
public enum LogEffect: Sendable, Equatable {
    /// Put the process-wide ring in this mode.
    case mode(LogRingMode)
    /// Take one batch from the ring and feed it back as `.logs(.batch)` in the same turn.
    case ready
}

/// What the host's log receiver delivers to the hub.
public enum LogDelivery: Sendable, Equatable {
    /// Records the peer forwarded, normalized.
    case records([LogRecordValue])
    /// The peer's ring evicted this many records unsent.
    case dropped(UInt64)
}

// MARK: - Peer

/// The peer's log forwarder (§7.3): at most one LOG_FORWARD per connection.
public struct LogForwarder: FeatureMachine {
    /// LOGS.
    public static let feature = FeatureID.logs

    private var availability: Availability<NoParams>
    private var stream: StreamID?
    private var ending = false
    /// After a RESET other than the host's DISABLED_BY_POLICY, no reopening
    /// until the next policy or usability change.
    private var blocked = false
    private var recordsMayWait = true
    private var modeSent: LogRingMode?
    private var lastUsable = false
    private(set) var outbox: [PeerEffect] = []
    private(set) var diagnostics: [Diagnostic] = []

    /// A forwarder; `availability` is absent when the build forwards no logs.
    public init(availability: Availability<NoParams>) {
        self.availability = availability
    }

    /// The `LogCapability` advert, or the absence.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { _ in Data() })
    }

    /// The forwarder sets no deadlines.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? { nil }

    mutating func takeOutputs() -> (effects: [PeerEffect], diagnostics: [Diagnostic]) {
        defer {
            outbox.removeAll()
            diagnostics.removeAll()
        }
        return (outbox, diagnostics)
    }

    /// Handles a connection event.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .policyChanged:
            if let policy = connection.currentPolicy {
                let mode: LogRingMode = policy.isEnabled(.logs) ? .forwarding : .discarding
                if mode != modeSent {
                    modeSent = mode
                    blocked = false
                    outbox.append(.logs(.mode(mode)))
                }
            }
            reconcile(&connection)
        case .usabilityChanged:
            reconcile(&connection)
        case .writable(let id) where id == stream:
            checkReady(&connection)
        case .remoteEnded(let id, _) where id == stream && !ending:
            diagnostics.append(.remoteViolation("the host ended LOG_FORWARD before the peer did"))
            if connection.canReset(id) { connection.reset(id, WireError(.streamProtocolError)) }
        case .streamClosed(let id, let closure) where id == stream:
            stream = nil
            ending = false
            switch closure {
            case .completed: reconcile(&connection)
            // The host's session messages leave before its stream RESETs (§3.5), so
            // this side already holds a policy at least as new as the one that
            // disabled the stream: reconcile reopens only if that policy enables LOGS.
            case .resetByPeer(let error) where error.code == .disabledByPolicy: reconcile(&connection)
            case .resetByPeer, .resetLocally: blocked = true
            case .connectionClosedLocally, .connectionClosedByPeer, .connectionLost: break
            }
        case .sessionEstablished, .opened, .message, .data, .remoteEnded, .writable, .streamClosed, .deadline:
            break
        }
    }

    /// Handles the sink's and the runtime's input.
    public mutating func handle(input: LogInput, connection: inout Connection, now: CoreInstant) {
        switch input {
        case .recordsAvailable:
            recordsMayWait = true
        case .batch(let batch):
            recordsMayWait = true
            guard let stream, !ending, !batch.records.isEmpty || batch.droppedBefore > 0 else { break }
            let message = batch.encoded
            if connection.canSendMessage(message.count, on: stream) {
                connection.send(message: message, on: stream)
            } else {
                diagnostics.append(.localFault("a log batch of \(message.count) bytes arrived unsendable"))
            }
        }
        checkReady(&connection)
    }

    private mutating func reconcile(_ connection: inout Connection) {
        let usable = connection.usability(.logs).isAvailable
        if usable != lastUsable {
            lastUsable = usable
            blocked = false
        }
        if let stream, !ending, !usable, connection.canQueue(on: stream) {
            connection.end(stream, body: Data())
            ending = true
        }
        if stream == nil, usable, !blocked, connection.canOpen(.logForward) {
            stream = connection.open(.logForward, body: Kernova_V2_LogOpen().encoded)
            ending = false
        }
        checkReady(&connection)
    }

    /// Asks for a batch once a whole one is sendable. It waits for the credit
    /// `.writable` rises at, not the smaller batch bound: readiness is re-checked
    /// only on `.writable`, so any lower threshold would leave credit between the
    /// two with nothing to re-check it.
    private mutating func checkReady(_ connection: inout Connection) {
        guard let stream, !ending, recordsMayWait,
            connection.canSendMessage(Limits.writableLowWater, on: stream)
        else { return }
        recordsMayWait = false
        outbox.append(.logs(.ready))
    }
}

// MARK: - Host

/// The host's log receiver (§7.4).
public struct LogReceiver: FeatureMachine {
    /// LOGS.
    public static let feature = FeatureID.logs
    /// The credit-return cap: bytes per second, and the burst.
    static let returnRate = (bytesPerSecond: 1_048_576, burst: 262_144)

    private var streams: [StreamID] = []
    private(set) var outbox: [HostEvent] = []
    private(set) var diagnostics: [Diagnostic] = []

    /// A receiver for one connection.
    public init() {}

    /// The host advertises LOGS available.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: .available(Kernova_V2_LogCapability().encoded))
    }

    /// The receiver sets no deadlines; the connection meters the credit return.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? { nil }

    mutating func takeOutputs() -> (events: [HostEvent], diagnostics: [Diagnostic]) {
        defer {
            outbox.removeAll()
            diagnostics.removeAll()
        }
        return (outbox, diagnostics)
    }

    /// Handles a connection event.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .opened(let id, _):
            streams.append(id)
            connection.setCreditReturnRate(Self.returnRate.bytesPerSecond, burst: Self.returnRate.burst, on: id)
        case .message(let id, let payload):
            guard let batch = try? Kernova_V2_LogBatch(serializedBytes: payload) else {
                diagnostics.append(.remoteViolation("a LogBatch that does not decode"))
                if connection.canReset(id) { connection.reset(id, WireError(.malformedMessage)) }
                return
            }
            if batch.records.count > LogRing.batchRecords {
                diagnostics.append(.remoteViolation("a LogBatch of \(batch.records.count) records"))
            }
            if batch.records.contains(where: { $0.segments.count > LogRecordValue.maxSegments }) {
                diagnostics.append(.remoteViolation("a LogRecord past 256 segments"))
            }
            if batch.droppedBefore > 0 {
                outbox.append(.log(.dropped(batch.droppedBefore)))
            }
            let records = batch.records.prefix(LogRing.batchRecords).map(LogRecordValue.init(received:))
            if !records.isEmpty {
                outbox.append(.log(.records(Array(records))))
            }
        case .remoteEnded(let id, _):
            if connection.canQueue(on: id) { connection.end(id, body: Data()) }
        case .streamClosed(let id, _):
            streams.removeAll { $0 == id }
        case .policyChanged, .usabilityChanged:
            guard case .absent(.disabledByPolicy, _) = connection.usability(.logs) else { return }
            for id in streams where connection.canReset(id) {
                connection.reset(id, WireError(.disabledByPolicy))
            }
        case .sessionEstablished, .data, .writable, .deadline:
            break
        }
    }
}
