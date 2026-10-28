#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a peer's installer adapter reports.
public enum UpdateInput: Sendable, Equatable {
    /// The formats it installs and the install's rejected hash, now and on change.
    case availability(Availability<UpdateOffer>)
    /// It wrote this many bytes of the pull's payload.
    case consumed(UpdatePullID, Int)
    /// It verified and installed the payload in the spare slot.
    case installed(UpdatePullID)
    /// It rejected the payload; nothing changed.
    case rejected(UpdatePullID, WireError)
    /// It failed mid-stream (`DISK_FULL`, …).
    case failed(UpdatePullID, WireError)
}

/// What a peer's update client asks its installer to do.
public enum UpdateEffect: Sendable, Equatable {
    /// Write these payload bytes, then report `.consumed`.
    case payload(UpdatePullID, Data)
    /// Every byte arrived: verify the hash and install.
    case complete(UpdatePullID, UpdateManifestValue)
    /// Drop whatever the pull wrote.
    case abort(UpdatePullID)
    /// Record this hash as the install's rejected hash.
    case recordRejected(Data)
    /// Clear the install's rejected hash.
    case clearRejected
}

/// A peer's verdict on a pull: the domain form of `UpdateResult`.
public struct UpdateResultValue: Sendable, Equatable {
    /// Staged or rejected.
    public enum Kind: Sendable, Equatable {
        /// Installed in the spare slot; the peer switches and relaunches.
        case staged
        /// Nothing changed; `error` says why.
        case rejected
    }

    /// The verdict.
    public var kind: Kind
    /// Why, when rejected.
    public var error: WireError?

    /// Creates a result.
    public init(kind: Kind, error: WireError? = nil) {
        self.kind = kind
        self.error = error
    }

    var encoded: Data {
        var result = Kernova_V2_UpdateResult()
        result.kind = kind == .staged ? .staged : .rejected
        if let error { result.error = error.proto }
        return result.encoded
    }
}

/// What the host's update server tells the hub. The payload's bytes pass between the endpoint and its
/// payload source as `HostEffect.read` and `PayloadInput`, never through the hub.
public enum UpdateServeEvent: Sendable, Equatable {
    /// The peer pulls the offered payload.
    case pullRequested(UpdatePullID, UpdateManifestValue)
    /// The peer's verdict.
    case result(UpdatePullID, UpdateResultValue)
    /// The pull ended without a verdict.
    case closed(UpdatePullID, StreamClosure)
}

// MARK: - Peer

/// The peer's update client: decides when to pull and checks the
/// byte count; the rejected hash comes from the installer's reports only.
public struct UpdateClient: FeatureMachine {
    /// UPDATE.
    public static let feature = FeatureID.update

    private struct Pull: Sendable {
        var id: UpdatePullID
        var manifest: UpdateManifestValue
        var received: UInt64 = 0
        /// The installer holds no state for it any more (it ended, or was told to abort).
        var settled = false
    }

    private var availability: Availability<UpdateOffer>
    private let ownHash: Data
    private let generation: ConnectionGeneration
    private var offered: UpdateManifestValue?
    /// The offered hash a `.clearRejected` was emitted for.
    private var clearedFor: Data?
    /// Hashes pulled on this connection; none is pulled twice on one connection.
    private var attempted: [Data] = []
    private var pull: Pull?
    private(set) var outbox: [PeerEffect] = []
    private(set) var diagnostics: [Diagnostic] = []

    /// A client for an install whose payload hash is `ownHash`.
    public init(availability: Availability<UpdateOffer>, ownHash: Data, generation: ConnectionGeneration) {
        self.availability = availability
        self.ownHash = ownHash
        self.generation = generation
    }

    /// The `UpdateCapability` advert, or the installer's absence.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { $0.encodedCapability })
    }

    /// The client sets no deadlines.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? { nil }

    mutating func takeOutputs() -> (effects: [PeerEffect], diagnostics: [Diagnostic]) {
        defer {
            outbox.removeAll()
            diagnostics.removeAll()
        }
        return (outbox, diagnostics)
    }

    /// The host's latest offer.
    mutating func offerChanged(_ manifest: UpdateManifestValue?, connection: inout Connection) {
        offered = manifest
        consider(&connection)
    }

    /// Handles a connection event.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .sessionEstablished, .usabilityChanged, .slotFreed:
            consider(&connection)
        case .data(let stream, let bytes):
            guard var current = pull, current.id.stream == stream, !current.settled else { return }
            if current.received + UInt64(bytes.count) > current.manifest.payloadSize {
                current.settled = true
                pull = current
                outbox.append(.update(.abort(current.id)))
                outbox.append(.update(.recordRejected(current.manifest.payloadHash)))
                if connection.canReset(stream) { connection.reset(stream, WireError(.updateSizeMismatch)) }
                return
            }
            current.received += UInt64(bytes.count)
            pull = current
            outbox.append(.update(.payload(current.id, bytes)))
        case .remoteEnded(let stream, _):
            guard var current = pull, current.id.stream == stream, !current.settled else { return }
            if current.received < current.manifest.payloadSize {
                current.settled = true
                pull = current
                outbox.append(.update(.abort(current.id)))
                outbox.append(.update(.recordRejected(current.manifest.payloadHash)))
                end(stream, UpdateResultValue(kind: .rejected, error: WireError(.updateSizeMismatch)), &connection)
            } else {
                outbox.append(.update(.complete(current.id, current.manifest)))
            }
        case .streamClosed(let stream, _):
            guard let current = pull, current.id.stream == stream else { return }
            if !current.settled { outbox.append(.update(.abort(current.id))) }
            pull = nil
            consider(&connection)
        case .policyChanged, .opened, .message, .writable, .deadline:
            break
        }
    }

    /// Handles the installer's report.
    public mutating func handle(input: UpdateInput, connection: inout Connection, now: CoreInstant) {
        switch input {
        case .availability(let availability):
            self.availability = availability
            consider(&connection)
        case .consumed(let id, let count):
            guard id.generation == generation, pull?.id == id else { return }
            connection.consumed(count, on: id.stream)
        case .installed(let id):
            settle(id, &connection) { $0.end($1, UpdateResultValue(kind: .staged), &$2) }
        case .rejected(let id, let error):
            settle(id, &connection) { $0.end($1, UpdateResultValue(kind: .rejected, error: error), &$2) }
        case .failed(let id, let error):
            settle(id, &connection) { _, stream, connection in
                if connection.canReset(stream) { connection.reset(stream, WireError(error.code)) }
            }
        }
    }

    private mutating func settle(
        _ id: UpdatePullID, _ connection: inout Connection,
        _ action: (inout UpdateClient, StreamID, inout Connection) -> Void
    ) {
        guard id.generation == generation, var current = pull, current.id == id, !current.settled else {
            if id.generation == generation {
                diagnostics.append(.localFault("installer report for a pull that is not waiting on it"))
            }
            return
        }
        current.settled = true
        pull = current
        action(&self, id.stream, &connection)
    }

    private func end(_ stream: StreamID, _ result: UpdateResultValue, _ connection: inout Connection) {
        guard connection.canQueue(on: stream) else { return }
        connection.end(stream, body: result.encoded)
    }

    private mutating func consider(_ connection: inout Connection) {
        guard let offered, case .available(let offer) = availability else { return }
        var rejected = offer.rejectedHash
        if let hash = rejected, hash != offered.payloadHash {
            if clearedFor != offered.payloadHash {
                clearedFor = offered.payloadHash
                outbox.append(.update(.clearRejected))
            }
            rejected = nil
        }
        guard pull == nil, offered.payloadHash != ownHash, offer.formats.contains(offered.format),
            offered.payloadHash != rejected, !attempted.contains(offered.payloadHash),
            connection.canOpen(.updatePull)
        else { return }
        var body = Kernova_V2_UpdatePull()
        body.payloadHash = offered.payloadHash
        let stream = connection.open(.updatePull, body: body.encoded)
        guard stream != .session else { return }
        attempted.append(offered.payloadHash)
        pull = Pull(id: UpdatePullID(generation: generation, stream: stream), manifest: offered)
    }
}

// MARK: - Host

/// The host's update server: serves exactly the offered manifest's
/// `payload_size` bytes, a read of the payload source at a time, then
/// ends the stream itself. A source that returns nothing short of the size,
/// more than a read asked for, or bytes no read asked for has failed: the pull
/// is RESET `READ_FAILED`, which the next connection retries, rather than
/// reaching the peer as a payload of the wrong size.
public struct UpdateServer: FeatureMachine {
    /// UPDATE.
    public static let feature = FeatureID.update

    private struct Pull: Sendable {
        var id: UpdatePullID
        var manifest: UpdateManifestValue
        /// Payload bytes queued so far.
        var sent: UInt64 = 0
        /// The most bytes the outstanding read may return; nil when none is outstanding.
        var granted: Int?
        var ended = false
        var resultDelivered = false
    }

    private let generation: ConnectionGeneration
    private var pull: Pull?
    private(set) var outbox: [HostEvent] = []
    private(set) var reads: [HostEffect] = []
    private(set) var diagnostics: [Diagnostic] = []

    /// A server for one connection.
    public init(generation: ConnectionGeneration) {
        self.generation = generation
    }

    /// The host advertises UPDATE available with empty params.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: .available(Data()))
    }

    /// The server sets no deadlines.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? { nil }

    mutating func takeOutputs() -> (events: [HostEvent], effects: [HostEffect], diagnostics: [Diagnostic]) {
        defer {
            outbox.removeAll()
            reads.removeAll()
            diagnostics.removeAll()
        }
        return (outbox, reads, diagnostics)
    }

    /// Handles a connection event.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .opened(let stream, let body):
            let request = (try? Kernova_V2_UpdatePull(serializedBytes: body)) ?? Kernova_V2_UpdatePull()
            guard let offer = connection.offeredUpdate else {
                return connection.reset(stream, WireError(.updateUnavailable))
            }
            guard request.payloadHash == offer.payloadHash else {
                return connection.reset(stream, WireError(.updateStale))
            }
            let id = UpdatePullID(generation: generation, stream: stream)
            pull = Pull(id: id, manifest: offer)
            outbox.append(.update(.pullRequested(id, offer)))
            serve(&connection)
        case .writable(let stream) where pull?.id.stream == stream:
            serve(&connection)
        case .remoteEnded(let stream, let body):
            guard var current = pull, current.id.stream == stream else { return }
            guard current.ended else {
                diagnostics.append(.remoteViolation("the peer ended UPDATE_PULL before the host"))
                if connection.canReset(stream) { connection.reset(stream, WireError(.streamProtocolError)) }
                return
            }
            let decoded = (try? Kernova_V2_UpdateResult(serializedBytes: body)) ?? Kernova_V2_UpdateResult()
            let error = decoded.hasError ? WireError(received: decoded.error) : nil
            let result = UpdateResultValue(kind: decoded.kind == .staged ? .staged : .rejected, error: error)
            current.resultDelivered = true
            pull = current
            outbox.append(.update(.result(current.id, result)))
        case .streamClosed(let stream, let closure):
            guard let current = pull, current.id.stream == stream else { return }
            if !current.resultDelivered { outbox.append(.update(.closed(current.id, closure))) }
            pull = nil
        case .sessionEstablished, .usabilityChanged, .policyChanged, .message, .data, .writable, .deadline, .slotFreed:
            break
        }
    }

    /// The offer changed: a pull of another manifest is stale.
    mutating func offerChanged(_ manifest: UpdateManifestValue?, connection: inout Connection) {
        guard let current = pull, current.manifest != manifest, connection.canReset(current.id.stream) else { return }
        connection.reset(current.id.stream, WireError(.updateStale))
    }

    /// The payload source returned bytes for the outstanding read.
    mutating func bytes(_ id: UpdatePullID, _ data: Data, connection: inout Connection) {
        guard var current = pull, current.id == id, !current.ended, connection.canQueue(on: id.stream) else { return }
        guard let granted = current.granted else {
            return sourceFailed(id, "the payload source sent \(data.count) bytes no read asked for", &connection)
        }
        current.granted = nil
        pull = current
        guard !data.isEmpty else {
            let short = current.manifest.payloadSize - current.sent
            return sourceFailed(id, "the payload source returned no bytes \(short) short of payload_size", &connection)
        }
        guard data.count <= granted, data.count <= connection.writableData(id.stream) else {
            return sourceFailed(
                id, "the payload source returned \(data.count) bytes for a \(granted)-byte read", &connection)
        }
        connection.send(data: data, on: id.stream)
        current.sent += UInt64(data.count)
        pull = current
        serve(&connection)
    }

    /// The payload source failed.
    mutating func failed(_ id: UpdatePullID, _ error: WireError, connection: inout Connection) {
        guard let current = pull, current.id == id, connection.canReset(id.stream) else { return }
        connection.reset(id.stream, error)
    }

    /// Ends the pull once `payload_size` bytes are queued; otherwise asks the
    /// source for the next read once the stream is writable, never past the size.
    private mutating func serve(_ connection: inout Connection) {
        guard var current = pull, !current.ended, current.granted == nil, connection.canQueue(on: current.id.stream)
        else { return }
        let remaining = current.manifest.payloadSize - current.sent
        guard remaining > 0 else {
            current.ended = true
            pull = current
            return connection.end(current.id.stream, body: Data())
        }
        let writable = connection.writableData(current.id.stream)
        guard writable >= Limits.writableLowWater else { return }
        let grant = min(writable, WireConstants.maxRawDataPayload, Int(clamping: remaining))
        current.granted = grant
        pull = current
        reads.append(.read(current.id, current.manifest, offset: current.sent, maxBytes: grant))
    }

    private mutating func sourceFailed(_ id: UpdatePullID, _ detail: String, _ connection: inout Connection) {
        diagnostics.append(.localFault(detail))
        if connection.canReset(id.stream) { connection.reset(id.stream, WireError(.readFailed, debugDetail: detail)) }
    }
}
