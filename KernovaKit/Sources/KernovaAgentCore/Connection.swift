#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// One connection's frames, streams, credit, Hello, liveness and close, with no
/// I/O: bytes go in through `receive`, frames come out through `pollTransmit`,
/// everything else through `pollEvent`. Kind-aware only through its
/// configuration's kind table.
public struct Connection: Sendable {
    // MARK: Configuration

    let configuration: ConnectionConfiguration
    let role: PeerRole
    var policy: ReceiverPolicy { configuration.policy }

    // MARK: Phase and time

    /// The connection's phase.
    public internal(set) var state = ConnectionState.handshaking
    /// The connection's raw and judged time.
    public internal(set) var clock: JudgedClock
    var closingDeadline: CoreInstant?
    /// How the connection ended, from its one `.closed` event on.
    var closure: ConnectionClosure?
    /// RESET(0) to send; set on entering `closing`.
    var closeError: WireError?
    /// Whether the queued session messages and control frames go before RESET(0)
    /// (a local close) or are dropped (a fatal error).
    var closeDrainsQueue = false

    // MARK: Wire

    var decoder = FrameDecoder()
    var preambleSent = false
    var sessionQueue: [SessionSlot] = []
    var sessionPayloads: [Data?] = Array(repeating: nil, count: SessionSlot.allCases.count)
    var pendingConnectionWindow = 0
    var pingPending = false
    var pingCounter: UInt64 = 0
    var nextPingAt: CoreInstant
    var roundRobinAfter: UInt32 = 0

    // MARK: Streams

    /// Every stream with state or pending frames, sorted by id.
    var streams: [StreamRecord] = []
    var nextLocalID: UInt64
    var highestLocalHandedOut: UInt32 = 0
    var highestRemoteOpened: UInt32 = 0
    var openBucket: TokenBucket

    // MARK: Credit

    // The two halves of the raw-DATA budget every raw sender shares (§3.4 S1):
    // any change to either moves each raw stream's S4 predicate, so the writable
    // refresh lives here rather than at each place that spends or refunds it.
    var connectionSendCredit = Limits.initialConnectionWindow {
        didSet { refreshAllWritable() }
    }
    var connectionReceiveRemaining = Limits.initialConnectionWindow
    var connectionHeldRaw = 0
    var connectionUnreturned = 0
    var queuedRawTotal = 0 {
        didSet { refreshAllWritable() }
    }

    // MARK: Session

    var localAdverts: [FeatureAdvertValue]
    /// The far side's Hello, once read.
    public internal(set) var remoteHello: RemoteHello?
    var remoteAdverts: [ReceivedAdvert] = []
    var remoteState: PeerSessionState?
    /// Host: its own policy, the one source of every `PolicyUpdate` it sends.
    /// Peer: the last `PolicyUpdate` read, nil before the first.
    public internal(set) var currentPolicy: PolicySnapshot?
    /// Host: the bundles it holds now, the one source of every offer it sends.
    var hostBundles: [BundledPayload] = []
    var lastPeerState: PeerSessionState?

    // MARK: Liveness

    var helloDeadline: JudgedDeadline?
    var unresponsiveDeadline: JudgedDeadline?
    var livenessCloseDeadline: JudgedDeadline?
    var lastHeard: CoreInstant
    /// Whether the far side is currently judged unresponsive.
    public internal(set) var isUnresponsive = false

    // MARK: Outputs

    var events: [RoutedEvent] = []
    var eventHead = 0
    var diagnosticWindowStart: CoreInstant?
    var diagnosticCount = 0
    var diagnosticsSuppressed = 0
    package var trace: [ConnectionTrace] = []

    /// Creates a connection that has just connected, its preamble and Hello queued.
    public init(_ configuration: ConnectionConfiguration, now: CoreInstant) {
        self.configuration = configuration
        role = configuration.claim.role
        clock = JudgedClock(now: now, suspendedStep: configuration.policy.suspendedStep)
        nextPingAt = now.advanced(by: configuration.policy.pingInterval)
        lastHeard = now
        nextLocalID = configuration.firstLocalStreamID ?? (configuration.claim.role == .host ? 2 : 1)
        openBucket = TokenBucket(
            capacity: configuration.policy.openBucketCapacity,
            perSecond: configuration.policy.openBucketRefillPerSecond, now: now)
        localAdverts = Self.sortedAdverts(configuration.adverts)
        if role == .host {
            currentPolicy = configuration.hostPolicy
            hostBundles = configuration.hostBundles
        }
        lastPeerState = configuration.initialState
        helloDeadline = JudgedDeadline(
            after: configuration.policy.helloTimeout, on: clock, confirmation: configuration.policy.expiryConfirmation)
        queueSession(.hello, payload: helloMessage().encoded)
    }

    // MARK: - Inputs

    /// Bytes as the transport delivered them, at any split.
    public mutating func receive(_ bytes: Data, now: CoreInstant) {
        ingest(bytes, now: now)
        while processNextFrame() {}
        finishReceive()
    }

    /// Advances the clocks and buffers bytes without processing them;
    /// `processNextFrame` handles one frame and `finishReceive` ends the turn.
    package mutating func ingest(_ bytes: Data, now: CoreInstant) {
        clock.advance(to: now)
        guard isAcceptingInput else { return }
        decoder.append(bytes)
    }

    /// The transport ended, in either direction.
    public mutating func transportEnded(now: CoreInstant) {
        tick(now)
        switch state {
        case .finished:
            return
        case .closing:
            finish()
        case .handshaking, .established:
            closeAllStreams(.connectionLost, keepPendingResets: false)
            dropAllQueues()
            finish()
            emit(.closed(.transportLost))
        }
    }

    /// The timer `nextDeadline` named fired (or any time: it only evaluates).
    public mutating func handleTimeout(now: CoreInstant) {
        tick(now)
    }

    /// Host only: the VM was live-paused (`true`) or resumed (`false`).
    public mutating func setPeerFrozen(_ frozen: Bool, now: CoreInstant) {
        tick(now)
        guard role == .host else { return misuse("setPeerFrozen on a peer") }
        guard frozen != clock.isFrozen else { return }
        clock.setFrozen(frozen)
        if !frozen, isAcceptingInput {
            pingPending = true
            nextPingAt = clock.raw.advanced(by: policy.pingInterval)
        }
        evaluate()
    }

    /// Closes the connection: queued session messages and control frames go
    /// first, then RESET(0) carrying `code`; every stream closes at once.
    public mutating func close(_ code: ErrorCode, retryAfter: CoreDuration?, now: CoreInstant) {
        tick(now)
        guard isAcceptingInput else { return }
        let error = WireError(code, retryAfter: retryAfter)
        closeAllStreams(.connectionClosedLocally(error), keepPendingResets: true)
        enterClosing(error, drainsQueue: true)
    }

    // MARK: - Queries

    /// The raw DATA a machine may send on `id` now (§3.4 S1), 0 when none.
    public func writableData(_ id: StreamID) -> Int {
        guard let index = index(of: id) else { return 0 }
        return writableData(at: index)
    }

    /// Whether a message of `byteCount` bytes is sendable on `id` now (§3.4 S2).
    public func canSendMessage(_ byteCount: Int, on id: StreamID) -> Bool {
        guard let index = index(of: id) else { return false }
        let record = streams[index]
        return record.canSend && record.sending == .messages && byteCount <= WireConstants.maxControlPayload
            && byteCount <= record.sendWindow && record.unsentMessages == 0 && isAcceptingInput
    }

    /// Whether this side may open a stream of `kind` now: its role opens it, its
    /// feature is usable (§4.3), and the concurrency and per-connection limits allow.
    public func canOpen(_ kind: StreamKind) -> Bool {
        openRefusal(kind) == nil
    }

    /// Why this side may not open a stream of `kind` now, nil when it may: the
    /// kind's role, then the connection's phase (before the Hello,
    /// `FEATURE_UNAVAILABLE`; once closing, the close's own error), the feature's
    /// usability, the 64-stream limit (`TOO_MANY_STREAMS`) and the kind's
    /// per-connection limit (its `duplicateCode`).
    public func openRefusal(_ kind: StreamKind) -> WireError? {
        guard let descriptor = descriptor(for: kind), opensAsThisRole(descriptor) else {
            return WireError(.unsupportedKind)
        }
        switch state {
        case .handshaking:
            return WireError(.featureUnavailable, debugDetail: "no Hello read yet")
        case .closing, .finished:
            return closure?.error ?? WireError(.unspecified, debugDetail: "the connection is closing")
        case .established:
            break
        }
        if let feature = descriptor.feature, case .absent(let reason, let detail) = usability(feature) {
            return WireError(.featureUnavailable, absence: reason, debugDetail: detail)
        }
        guard localSlotsInUse < Limits.maxConcurrentStreams else { return WireError(.tooManyStreams) }
        if let max = descriptor.maxPerConnection {
            let open = streams.count(where: { $0.isLocal && $0.kind == kind && $0.holdsSlot })
            guard open < max else { return WireError(descriptor.duplicateCode) }
        }
        return nil
    }

    /// The phase of `id`, nil once the stream is gone or for an unknown id.
    public func phase(of id: StreamID) -> StreamPhase? {
        index(of: id).map { streams[$0].phase }
    }

    /// Whether `feature` is usable on this connection (§4.3), with the far
    /// side's params when it is, or the first failing condition's reason.
    public func usability(_ feature: FeatureID) -> Availability<Data> {
        guard let remoteHello else { return .absent(.unspecified, debugDetail: "no Hello read yet") }
        guard let descriptor = FeatureDescriptor.lookup(feature) else {
            return .absent(.notImplemented, debugDetail: "")
        }
        if !descriptor.frozen, remoteHello.protocolVersion != configuration.protocolVersion {
            return .absent(.protocolMismatch, debugDetail: "")
        }
        guard let local = localAdverts.first(where: { $0.feature == feature })?.advert else {
            return .absent(.notImplemented, debugDetail: "")
        }
        if case .absent(let reason, let detail) = local.availability { return .absent(reason, debugDetail: detail) }
        guard let received = remoteAdverts.first(where: { $0.value.feature == feature }) else {
            return .absent(.notImplemented, debugDetail: "")
        }
        let remote = received.value.advert
        guard case .available(let params) = remote.availability else { return remote.availability }
        guard remote.version == local.version else { return .absent(.versionMismatch, debugDetail: "") }
        guard received.paramsDecode else {
            return .absent(.unspecified, debugDetail: "the far side's params do not decode")
        }
        if descriptor.policyGoverned {
            guard let currentPolicy else { return .absent(.disabledByPolicy, debugDetail: "policy undecided") }
            guard currentPolicy.isEnabled(feature) else { return .absent(.disabledByPolicy, debugDetail: "") }
        }
        return .available(params)
    }

    /// Host: what it offers this peer now, from its bundles and the peer's claim;
    /// nil before the peer's Hello and when no bundle fits.
    public var offeredUpdate: UpdateManifestValue? {
        guard role == .host, let claim = remoteHello?.claim else { return nil }
        return BundledPayload.offer(from: hostBundles, for: claim)
    }

    /// Every implemented feature's usability, in feature order.
    public var featureStatus: FeatureStatusTable {
        FeatureStatusTable(FeatureDescriptor.all.map { (feature: $0.feature, status: usability($0.feature)) })
    }

    /// When the driver must next call `handleTimeout`; nil once finished.
    public var nextDeadline: CoreInstant? {
        switch state {
        case .finished:
            return nil
        case .closing:
            return clock.external(closingDeadline)
        case .handshaking, .established:
            var deadline = clock.raw.advanced(by: .seconds(5))
            func consider(_ instant: CoreInstant?) {
                if let instant, instant < deadline { deadline = instant }
            }
            if !clock.isFrozen { consider(nextPingAt) }
            consider(helloDeadline?.wake(clock))
            consider(unresponsiveDeadline?.wake(clock))
            consider(livenessCloseDeadline?.wake(clock))
            if diagnosticsSuppressed > 0 { consider(diagnosticWindowStart?.advanced(by: .seconds(60))) }
            for record in streams {
                consider(record.creditReturnWake)
            }
            return clock.external(max(deadline, clock.raw))
        }
    }

    /// The connection's memory and credit now.
    public var footprint: MemoryFootprint {
        var control = sessionQueue.count + (pendingConnectionWindow > 0 ? 1 : 0) + (pingPending ? 1 : 0)
        var maxMessages = 0
        for record in streams {
            control += (record.pendingReset != nil ? 1 : 0) + (record.pendingWindow > 0 ? 1 : 0)
            maxMessages = max(maxMessages, record.unsentMessages)
        }
        return MemoryFootprint(
            heldRawBytes: connectionHeldRaw, decoderBufferedBytes: decoder.bufferedByteCount,
            queuedRawBytes: queuedRawTotal, maxQueuedMessagesPerStream: maxMessages, controlFrames: control,
            pendingEvents: events.count - eventHead, streamRecords: streams.count,
            connectionSendCredit: connectionSendCredit, connectionReceiveRemaining: connectionReceiveRemaining,
            unreturnedConnectionCredit: connectionUnreturned + pendingConnectionWindow)
    }

    // MARK: - Outputs

    /// The next event, in the order they happened.
    public mutating func pollEvent() -> ConnectionEvent? {
        pollRoutedEvent()?.event
    }

    package mutating func pollRoutedEvent() -> RoutedEvent? {
        guard eventHead < events.count else { return nil }
        let event = events[eventHead]
        eventHead += 1
        if eventHead == events.count {
            events.removeAll(keepingCapacity: true)
            eventHead = 0
        }
        return event
    }

    /// Takes the trace the simulation reads, emptying it.
    package mutating func takeTrace() -> [ConnectionTrace] {
        defer { trace.removeAll(keepingCapacity: true) }
        return trace
    }

    // MARK: - Internals shared by the extensions

    var isAcceptingInput: Bool { state == .handshaking || state == .established }

    var remoteRole: PeerRole? { remoteHello?.claim.role }

    func descriptor(for kind: StreamKind) -> StreamKindDescriptor? {
        configuration.kinds.first { $0.kind == kind }
    }

    func opensAsThisRole(_ descriptor: StreamKindDescriptor) -> Bool {
        (descriptor.openerRole == .host) == (role == .host)
    }

    /// Whether `id` has the parity this side opens.
    func isLocalParity(_ id: UInt32) -> Bool {
        (id % 2 == 0) == (role == .host)
    }

    var localSlotsInUse: Int {
        streams.count(where: { $0.isLocal && $0.holdsSlot })
    }

    /// Remote streams the far side still counts, refused ones awaiting their RESET included.
    var remoteSlotsCounted: Int {
        streams.count(where: { !$0.isLocal && $0.holdsSlot })
    }

    func index(of id: StreamID) -> Int? {
        var low = 0
        var high = streams.count
        while low < high {
            let middle = (low + high) / 2
            if streams[middle].id < id {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < streams.count && streams[low].id == id ? low : nil
    }

    mutating func insert(_ record: StreamRecord) {
        var low = 0
        var high = streams.count
        while low < high {
            let middle = (low + high) / 2
            if streams[middle].id < record.id {
                low = middle + 1
            } else {
                high = middle
            }
        }
        streams.insert(record, at: low)
    }

    func writableData(at index: Int) -> Int {
        let record = streams[index]
        guard record.canSend, record.sending == .rawData, isAcceptingInput else { return 0 }
        return max(0, min(record.sendWindow, connectionSendCredit, policy.senderRawBudget - queuedRawTotal))
    }

    static func sortedAdverts(_ adverts: [(FeatureID, LocalAdvert)]) -> [FeatureAdvertValue] {
        var kept: [FeatureAdvertValue] = []
        for (feature, advert) in adverts where !kept.contains(where: { $0.feature == feature }) {
            kept.append(FeatureAdvertValue(feature: feature, advert: advert))
        }
        return kept.sorted { $0.feature.rawValue < $1.feature.rawValue }
    }

    mutating func emit(_ event: ConnectionEvent, owner: KindOwner? = nil) {
        if configuration.recordsTrace {
            trace.append(.event(event))
        }
        if case .closed(let closure) = event { self.closure = closure }
        events.append(RoutedEvent(event: event, owner: owner))
    }

    /// Emits `diagnostic`, at most `diagnosticsPerMinute` a minute, then a count.
    mutating func diagnose(_ diagnostic: Diagnostic) {
        rollDiagnosticWindow()
        if diagnosticWindowStart == nil { diagnosticWindowStart = clock.raw }
        if diagnosticCount < policy.diagnosticsPerMinute {
            diagnosticCount += 1
            emit(.diagnostic(diagnostic))
        } else {
            diagnosticsSuppressed += 1
        }
    }

    mutating func rollDiagnosticWindow() {
        guard let start = diagnosticWindowStart, clock.raw >= start.advanced(by: .seconds(60)) else { return }
        if diagnosticsSuppressed > 0 {
            emit(.diagnostic(.suppressed(diagnosticsSuppressed)))
        }
        diagnosticWindowStart = nil
        diagnosticCount = 0
        diagnosticsSuppressed = 0
    }

    /// A command the core's state forbids (§9.6): a bug in a core machine.
    mutating func misuse(_ what: String) {
        if configuration.assertsOnMisuse {
            assertionFailure("Connection misuse: \(what)")
        }
        diagnose(.localFault("misuse: \(what)"))
        fatal(.internal, what)
    }
}

/// One far-side advert, normalized, with whether its params decode as this
/// build's capability message: decided once, when the advert is read.
struct ReceivedAdvert: Sendable, Equatable {
    var value: FeatureAdvertValue
    var paramsDecode: Bool
}

/// An event with the machine that owns its stream, for the endpoint's routing.
package struct RoutedEvent: Sendable, Equatable {
    package var event: ConnectionEvent
    package var owner: KindOwner?
}

/// The session messages a side sends, each kind but Hello coalescing (§3.5 step 2).
enum SessionSlot: Int, CaseIterable, Sendable {
    case hello, peerState, capabilities, policy, updateAvailable
}
