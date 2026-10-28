#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import SwiftProtobuf
import Testing

/// The machine-by-machine unit suites: each pins one table of the phase 2 spec.
@Suite("Agent core units")
struct CoreUnits {}

/// Frame and message builders the unit suites share, beside `WireFrames`.
enum Unit {
    static let t0 = CoreInstant(nanoseconds: 1_000_000_000)

    static func at(_ milliseconds: Int64) -> CoreInstant {
        t0.advanced(by: .milliseconds(milliseconds))
    }

    static func encode(_ message: some SwiftProtobuf.Message) -> Data {
        (try? message.serializedBytes()) ?? Data()
    }

    static func end(_ stream: UInt32, _ body: Data = Data()) -> Frame {
        Frame(streamID: StreamID(rawValue: stream), type: .end, payload: body)
    }

    static func raw(_ stream: UInt32, _ bytes: Data) -> Frame {
        Frame(streamID: StreamID(rawValue: stream), type: .data, payload: bytes)
    }

    static func rawMessage(_ stream: UInt32, _ payload: Data) -> Frame {
        Frame(streamID: StreamID(rawValue: stream), type: .data, flags: .message, payload: payload)
    }

    static func window(_ payload: Data) -> UInt32 {
        payload.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func error(_ payload: Data) -> Kernova_V2_Error {
        (try? Kernova_V2_Error(serializedBytes: payload)) ?? Kernova_V2_Error()
    }

    static func progress(_ stage: Kernova_V2_PowerProgress.Stage, apps: Int = 0) -> Kernova_V2_PowerProgress {
        var progress = Kernova_V2_PowerProgress()
        progress.stage = stage
        progress.apps = (0..<apps).map { index in
            var app = Kernova_V2_BlockingApp()
            app.displayName = "App \(index)"
            return app
        }
        return progress
    }

    static func outcome(
        _ kind: Kernova_V2_PowerOutcome.Kind, _ code: ErrorCode? = nil, apps: Int = 0
    ) -> Data {
        var outcome = Kernova_V2_PowerOutcome()
        outcome.kind = kind
        if let code { outcome.error.code = code }
        outcome.apps = progress(.waitingOnApps, apps: apps).apps
        return encode(outcome)
    }

    static func powerRequest(_ action: PowerAction, deadlineMs: UInt32 = 10_000) -> Kernova_V2_PowerRequest {
        var request = Kernova_V2_PowerRequest()
        request.action = action
        request.acceptanceDeadlineMs = deadlineMs
        return request
    }

    static func policy(logs: Bool) -> Frame {
        WireFrames.session { message in
            var entry = Kernova_V2_FeaturePolicy()
            entry.feature = .logs
            entry.version = 1
            entry.enabled = logs
            message.policy.features = [entry]
        }
    }

    static func updateAvailable(_ manifest: UpdateManifestValue?) -> Frame {
        WireFrames.session { message in
            var available = Kernova_V2_UpdateAvailable()
            if let manifest {
                available.manifest.payloadHash = manifest.payloadHash
                available.manifest.payloadSize = manifest.payloadSize
                available.manifest.format = manifest.format
                available.manifest.versionLabel = manifest.versionLabel
            }
            message.updateAvailable = available
        }
    }

    /// A `CapabilityUpdate` listing the three features, each available unless withdrawn.
    static func capabilities(
        withdrawing withdrawn: FeatureID? = nil, reason: AbsenceReason = .notOnConsole,
        powerActions: [PowerAction] = [.shutdown, .restart]
    ) -> Frame {
        WireFrames.session { message in
            message.capabilities.features = [FeatureID.power, .update, .logs].map { feature in
                var advert = Kernova_V2_FeatureAdvert()
                advert.feature = feature
                advert.version = 1
                if feature == withdrawn {
                    advert.absent.reason = reason
                } else if feature == .power {
                    var capability = Kernova_V2_PowerCapability()
                    capability.actions = powerActions
                    advert.params = encode(capability)
                } else {
                    advert.params = Data()
                }
                return advert
            }
        }
    }

    static func manifest(tag: UInt64 = 1, size: UInt64 = 100_000, format: PayloadFormat = .executable)
        -> UpdateManifestValue
    {
        UpdateManifestValue(
            payloadHash: SimHub.tagHash(tag), payloadSize: size, format: format, versionLabel: "2.\(tag)")
    }

    static func hostAdverts() -> [(FeatureID, LocalAdvert)] {
        [
            (.power, LocalAdvert(version: 1, availability: .available(Data()))),
            (.update, LocalAdvert(version: 1, availability: .available(Data()))),
            (.logs, LocalAdvert(version: 1, availability: .available(Data()))),
        ]
    }

    static func peerAdverts() -> [(FeatureID, LocalAdvert)] {
        var power = Kernova_V2_PowerCapability()
        power.actions = [.shutdown, .restart]
        var update = Kernova_V2_UpdateCapability()
        update.formats = [.executable]
        return [
            (.power, LocalAdvert(version: 1, availability: .available(encode(power)))),
            (.update, LocalAdvert(version: 1, availability: .available(encode(update)))),
            (.logs, LocalAdvert(version: 1, availability: .available(Data()))),
        ]
    }

    /// A policy that judges nothing for an hour, so a test may idle without PINGs.
    static var patientPolicy: ReceiverPolicy {
        var policy = ReceiverPolicy.production
        policy.unresponsiveAfter = .seconds(3_600)
        policy.closeAfter = .seconds(7_200)
        return policy
    }
}

/// One `Connection` under test against a raw far side: frames go in as bytes,
/// what it writes is decoded back into frames.
struct Wire {
    var connection: Connection
    var now = Unit.t0
    private var outbound = FrameDecoder()

    init(_ configuration: ConnectionConfiguration) {
        connection = Connection(configuration, now: Unit.t0)
    }

    /// A host connection over the three features, LOGS enabled by policy.
    static func host(
        policy: ReceiverPolicy = .production, configure: (inout ConnectionConfiguration) -> Void = { _ in }
    ) -> Wire {
        var configuration = ConnectionConfiguration(
            claim: PeerClaim(role: .host), adverts: Unit.hostAdverts(), sessionToken: Data(repeating: 9, count: 16),
            hostPolicy: PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)]), policy: policy)
        configuration.assertsOnMisuse = false
        configure(&configuration)
        return Wire(configuration)
    }

    /// A session peer connection over the three features.
    static func peer(
        policy: ReceiverPolicy = .production, configure: (inout ConnectionConfiguration) -> Void = { _ in }
    ) -> Wire {
        var configuration = ConnectionConfiguration(
            claim: PeerClaim(
                role: .sessionPeer, scope: .user, os: .linux, architecture: .arm64,
                payloadHash: Data(repeating: 0xA1, count: 32), instanceID: Data(repeating: 2, count: 16)),
            initialState: PeerSessionState(console: .on, sessionID: "c1"), adverts: Unit.peerAdverts(),
            policy: policy)
        configuration.assertsOnMisuse = false
        configure(&configuration)
        return Wire(configuration)
    }

    /// The far side's preamble and Hello; established at once, its first output discarded.
    mutating func establish(_ hello: Frame? = nil) {
        let far = hello ?? WireFrames.hello(role: connection.configuration.claim.role == .host ? .sessionPeer : .host)
        feed([far], preamble: true)
        _ = flush()
        _ = takeEvents()
    }

    mutating func feed(_ frames: [Frame], preamble: Bool = false) {
        connection.receive(WireFrames.bytes(frames, preamble: preamble), now: now)
    }

    mutating func advance(to instant: CoreInstant) {
        now = instant
        connection.handleTimeout(now: now)
    }

    mutating func advance(by span: CoreDuration) {
        advance(to: now.advanced(by: span))
    }

    /// Every frame the connection hands out now, in order.
    mutating func flush(maxBytes: Int = 1 << 20) -> [Frame] {
        var frames: [Frame] = []
        while let transmit = connection.pollTransmit(maxBytes: maxBytes) {
            for chunk in transmit.chunks { outbound.append(chunk) }
            while let frame = try? outbound.nextFrame() { frames.append(frame) }
        }
        return frames
    }

    mutating func takeEvents() -> [ConnectionEvent] {
        var events: [ConnectionEvent] = []
        while let event = connection.pollEvent() { events.append(event) }
        return events
    }
}

/// Two real connections, host and session peer, joined by in-memory bytes.
struct Pair {
    var host: Wire
    var peer: Wire
    var hostEvents: [ConnectionEvent] = []
    var peerEvents: [ConnectionEvent] = []

    init(testKinds: Bool = true) {
        host = Wire.host { if testKinds { $0.addTestKinds() } }
        peer = Wire.peer { if testKinds { $0.addTestKinds() } }
        settle()
    }

    /// Bytes the host hands out now, not yet delivered.
    mutating func takeHostBytes() -> Data {
        var data = Data()
        while let transmit = host.connection.pollTransmit(maxBytes: 1 << 20) {
            for chunk in transmit.chunks { data.append(chunk) }
        }
        return data
    }

    mutating func takePeerBytes() -> Data {
        var data = Data()
        while let transmit = peer.connection.pollTransmit(maxBytes: 1 << 20) {
            for chunk in transmit.chunks { data.append(chunk) }
        }
        return data
    }

    mutating func hostToPeer() {
        let bytes = takeHostBytes()
        if !bytes.isEmpty { peer.connection.receive(bytes, now: peer.now) }
        collect()
    }

    mutating func peerToHost() {
        let bytes = takePeerBytes()
        if !bytes.isEmpty { host.connection.receive(bytes, now: host.now) }
        collect()
    }

    mutating func settle() {
        for _ in 0..<8 {
            hostToPeer()
            peerToHost()
        }
    }

    mutating func collect() {
        hostEvents += host.takeEvents()
        peerEvents += peer.takeEvents()
    }

    /// §3.4's conservation sum for the direction `sender` → `receiver`.
    static func conserved(sender: Connection, receiver: Connection) -> Int {
        let send = sender.footprint
        let receive = receiver.footprint
        return send.connectionSendCredit + send.queuedRawBytes + receive.heldRawBytes
            + receive.unreturnedConnectionCredit
    }
}

/// The written frames of one stream, by type.
extension [Frame] {
    func on(_ stream: UInt32) -> [Frame] {
        filter { $0.streamID.rawValue == stream }
    }

    var shape: [String] {
        map { "\($0.streamID.rawValue):\($0.type)\($0.flags.contains(.message) ? "+msg" : "")" }
    }
}

extension HostileRun {
    /// Frames written since `count`.
    func written(since count: Int) -> [Frame] {
        Array(written.dropFirst(count))
    }

    /// Advances `span` in 500 ms steps, feeding a PING every `pingEvery` so the
    /// far side stays live.
    func advanceLive(_ span: SimTime, pingEvery: SimTime = .sec(2)) {
        var remaining = span
        while remaining > 0 {
            let take = Swift.min(pingEvery, remaining)
            advance(take)
            remaining -= take
            feed([WireFrames.ping()])
        }
    }
}
