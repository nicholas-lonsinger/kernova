#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import SwiftProtobuf

/// Frames a raw far side writes, for hostile scripts and transcripts.
package enum WireFrames {
    package static func message(_ stream: UInt32, _ message: some SwiftProtobuf.Message) -> Frame {
        Frame(
            streamID: StreamID(rawValue: stream), type: .data, flags: .message,
            payload: (try? message.serializedBytes()) ?? Data())
    }

    package static func session(_ build: (inout Kernova_V2_SessionMessage) -> Void) -> Frame {
        var message = Kernova_V2_SessionMessage()
        build(&message)
        return Self.message(0, message)
    }

    /// A Hello for `role`, POWER, UPDATE and LOGS available.
    package static func hello(
        role: Kernova_V2_PeerIdentity.Role, scope: Kernova_V2_PeerIdentity.InstallScope = .user,
        sessionID: String = "c1", protocolVersion: UInt32 = 1, powerActions: [PowerAction] = [.shutdown, .restart],
        instanceID: Data = Data(repeating: 0x11, count: 16), payloadHash: Data = Data(repeating: 0xA1, count: 32)
    ) -> Frame {
        session { message in
            var hello = Kernova_V2_Hello()
            hello.protocolVersion = protocolVersion
            hello.identity.role = role
            hello.identity.installScope = role == .host ? .unspecified : scope
            hello.identity.os = .linux
            hello.identity.architecture = .arm64
            hello.identity.versionLabel = "far"
            if role != .host {
                hello.identity.instanceID = instanceID
                hello.identity.payloadHash = payloadHash
                hello.state.sessionID = role == .sessionPeer ? sessionID : ""
                hello.state.console = .on
                hello.state.consoleSessionID = role == .systemPeer ? sessionID : ""
            } else {
                hello.sessionToken = Data(0..<16)
            }
            var power = Kernova_V2_FeatureAdvert()
            power.feature = .power
            power.version = 1
            var capability = Kernova_V2_PowerCapability()
            capability.actions = role == .host ? [] : powerActions
            power.params = (try? capability.serializedBytes()) ?? Data()
            var update = Kernova_V2_FeatureAdvert()
            update.feature = .update
            update.version = 1
            var formats = Kernova_V2_UpdateCapability()
            formats.formats = role == .host ? [] : [.executable]
            update.params = (try? formats.serializedBytes()) ?? Data()
            var logs = Kernova_V2_FeatureAdvert()
            logs.feature = .logs
            logs.version = 1
            logs.params = Data()
            hello.features = [power, update, logs]
            message.hello = hello
        }
    }

    package static func open(_ stream: UInt32, _ kind: StreamKind, body: some SwiftProtobuf.Message) -> Frame {
        var open = Kernova_V2_Open()
        open.kind = kind
        open.body = (try? body.serializedBytes()) ?? Data()
        return Frame(
            streamID: StreamID(rawValue: stream), type: .open, payload: (try? open.serializedBytes()) ?? Data())
    }

    package static func window(_ stream: UInt32, _ increment: UInt32) -> Frame {
        Frame(
            streamID: StreamID(rawValue: stream), type: .window,
            payload: Data([
                UInt8(truncatingIfNeeded: increment >> 24), UInt8(truncatingIfNeeded: increment >> 16),
                UInt8(truncatingIfNeeded: increment >> 8), UInt8(truncatingIfNeeded: increment),
            ]))
    }

    package static func reset(_ stream: UInt32, code: Int) -> Frame {
        var error = Kernova_V2_Error()
        error.code = ErrorCode(rawValue: code) ?? .UNRECOGNIZED(code)
        return Frame(
            streamID: StreamID(rawValue: stream), type: .reset, payload: (try? error.serializedBytes()) ?? Data())
    }

    package static func ping() -> Frame {
        Frame(streamID: .session, type: .ping, payload: Data(count: 8))
    }

    /// The preamble and the frames' bytes.
    package static func bytes(_ frames: [Frame], preamble: Bool = true) -> Data {
        var data = preamble ? WireConstants.preamble : Data()
        for frame in frames {
            for part in FrameEncoder.encode(frame) { data.append(part) }
        }
        return data
    }
}

/// One real endpoint against raw bytes (§10.2 `.hostile`): the script's bytes are
/// fed in seeded random splits, and what the endpoint writes is decoded.
package final class HostileRun {
    package var host: HostEndpoint?
    package var peer: PeerEndpoint?
    package var now = CoreInstant(nanoseconds: 1_000_000_000)
    private var rng: SplitMix64
    private var outbound = FrameDecoder()
    package private(set) var written: [Frame] = []
    package private(set) var hostEvents: [HostEvent] = []
    package private(set) var peerEvents: [PeerEvent] = []
    package private(set) var peerEffects: [PeerEffect] = []
    package private(set) var trace: [ConnectionTrace] = []
    /// While set, nothing is taken from `pollTransmit`: the far side reads nothing.
    package var writerStalled = false

    /// A real host endpoint (`local == .host`) holding `bundles`, or a real
    /// session peer whose process's power ledger is `powerLedger`.
    package init(
        local: SimSide, seed: UInt64, testKinds: Bool = false,
        bundles: [BundledPayload] = [SimHub.bundle(size: 100_000, tag: 1)], powerLedger: PowerLedger = PowerLedger(),
        tweak: @escaping @Sendable (inout ConnectionConfiguration) -> Void = { _ in }
    ) {
        rng = SplitMix64(seed: seed)
        let configure: @Sendable (inout ConnectionConfiguration) -> Void = { connection in
            connection.recordsTrace = true
            connection.assertsOnMisuse = false
            if testKinds { connection.addTestKinds() }
            tweak(&connection)
        }
        switch local {
        case .host:
            var configuration = HostConfiguration(
                claim: PeerClaim(role: .host), sessionToken: Data(repeating: 9, count: 16),
                policy: PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)]), bundles: bundles)
            configuration.tweak = configure
            host = HostEndpoint(configuration, generation: ConnectionGeneration(rawValue: 1), now: now)
        case .peer:
            var spec = PeerSpec.session()
            spec.installer = InstallerSpec()
            var configuration = PeerConfiguration(
                claim: spec.claim, state: spec.state, power: spec.power.offer, logs: .available(NoParams()),
                update: .available(UpdateOffer(formats: [.executable])))
            configuration.powerLedger = powerLedger
            configuration.tweak = configure
            peer = PeerEndpoint(configuration, generation: ConnectionGeneration(rawValue: 1), now: now)
        }
        drain()
    }

    package var state: ConnectionState? { host?.state ?? peer?.state }

    package var closure: ConnectionClosure? {
        for event in hostEvents { if case .closed(let closure) = event { return closure } }
        for event in peerEvents { if case .closed(let closure) = event { return closure } }
        return nil
    }

    package var connectionFootprint: MemoryFootprint? { host?.connection.footprint ?? peer?.connection.footprint }

    /// The code of the local side's RESET(0), when it closed.
    package var localCloseCode: ErrorCode? {
        if case .closedLocally(let error) = closure { return error.code }
        return nil
    }

    /// RESETs the endpoint wrote on streams other than 0.
    package var streamResets: [(stream: UInt32, code: ErrorCode)] {
        written.compactMap { frame in
            guard frame.type == .reset, frame.streamID != .session else { return nil }
            let error = (try? Kernova_V2_Error(serializedBytes: frame.payload)) ?? Kernova_V2_Error()
            return (frame.streamID.rawValue, error.code)
        }
    }

    /// Feeds `bytes` in seeded splits of 1 … `maxSplit` bytes, draining after each.
    package func feed(_ bytes: Data, maxSplit: Int = 4096) {
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let size = min(rng.int(in: 1...maxSplit), bytes.endIndex - offset)
            let chunk = bytes[offset..<(offset + size)]
            offset += size
            host?.receive(Data(chunk), now: now)
            peer?.receive(Data(chunk), now: now)
            drain()
        }
    }

    package func feed(_ frames: [Frame], preamble: Bool = false) {
        feed(WireFrames.bytes(frames, preamble: preamble))
    }

    package func advance(_ span: SimTime, step: SimTime = .ms(500)) {
        var remaining = span
        while remaining > 0 {
            let take = min(step, remaining)
            now = now.advanced(by: CoreDuration(nanoseconds: Int64(take)))
            remaining -= take
            host?.handleTimeout(now: now)
            peer?.handleTimeout(now: now)
            drain()
        }
    }

    package func command(_ command: HostCommand) {
        host?.handle(command, now: now)
        drain()
    }

    package func input(_ input: PeerInput) {
        peer?.handle(input, now: now)
        drain()
    }

    package func openTestBulk(_ kind: StreamKind, consumes: Bool) -> StreamID? {
        let stream =
            peer?.openTestBulk(kind, consumes: consumes, now: now)
            ?? host?.openTestBulk(kind, consumes: consumes, now: now)
        drain()
        return stream
    }

    package func drain() {
        var progressed = true
        while progressed {
            progressed = false
            while let event = host?.pollEvent() {
                hostEvents.append(event)
                progressed = true
            }
            while let event = peer?.pollEvent() {
                peerEvents.append(event)
                progressed = true
            }
            while let effect = peer?.pollEffect() {
                peerEffects.append(effect)
                progressed = true
            }
            while !writerStalled,
                let transmit = host?.pollTransmit(maxBytes: 1 << 20) ?? peer?.pollTransmit(maxBytes: 1 << 20)
            {
                progressed = true
                for chunk in transmit.chunks { outbound.append(chunk) }
                while let frame = try? outbound.nextFrame() { written.append(frame) }
            }
        }
        trace += host?.takeTrace() ?? []
        trace += peer?.takeTrace() ?? []
    }

    /// Property 1 and 3 over the trace: each stream closes once, nothing follows `.closed`.
    package var traceViolations: [String] {
        var open: Set<UInt32> = []
        var closed: Set<UInt32> = []
        var connectionClosed = false
        var violations: [String] = []
        for entry in trace {
            if connectionClosed { violations.append("event after .closed: \(entry)") }
            switch entry {
            case .localOpened(let id, _): open.insert(id.rawValue)
            case .event(.opened(let id, _, _)): open.insert(id.rawValue)
            case .event(.streamClosed(let id, _)):
                if !open.contains(id.rawValue) || closed.contains(id.rawValue) {
                    violations.append("stream \(id.rawValue) closed without being open")
                }
                open.remove(id.rawValue)
                closed.insert(id.rawValue)
            case .event(.closed): connectionClosed = true
            default: break
            }
        }
        if state != .established, !open.isEmpty, connectionClosed { violations.append("streams \(open) left open") }
        return violations
    }
}
