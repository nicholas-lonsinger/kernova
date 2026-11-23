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

/// The agent core's unit suites, one per machine or helper.
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

    static func powerRequest(
        _ action: PowerAction, deadlineMs: UInt32 = 10_000, ignoreApps: Bool = false
    ) -> Kernova_V2_PowerRequest {
        var request = Kernova_V2_PowerRequest()
        request.action = action
        request.acceptanceDeadlineMs = deadlineMs
        request.ignoreApps = ignoreApps
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
}

/// A bare connection driven as an endpoint drives it, with no machine to route its events to.
extension Connection {
    /// Bytes as the transport delivered them, at any split: every whole frame in them handled, then the turn ended.
    mutating func receive(_ bytes: Data, now: CoreInstant) {
        ingest(bytes, now: now)
        while processNextFrame() {}
        finishReceive()
    }

    /// The next event, in the order they happened.
    mutating func pollEvent() -> ConnectionEvent? {
        pollRoutedEvent()?.event
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
        configuration.assertsOnMisuseForTesting = false
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
        configuration.assertsOnMisuseForTesting = false
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
            if transmit.isFinal { connection.finalTransmitWritten(now: now) }
        }
        return frames
    }

    mutating func takeEvents() -> [ConnectionEvent] {
        var events: [ConnectionEvent] = []
        while let event = connection.pollEvent() { events.append(event) }
        return events
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
}
