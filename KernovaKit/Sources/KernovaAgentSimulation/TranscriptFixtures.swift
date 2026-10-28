#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// The named configurations a transcript's header refers to. A fixture fixes
/// every identity string, instance id, hash and advert; once a frozen transcript
/// names one, it never changes.
package enum TranscriptFixture {
    package static let token = Data(0..<16)

    /// A Linux session peer's install hash.
    package static let linuxSessionHash = Data(repeating: 0xA1, count: 32)
    /// A macOS system peer's install hash, also what `host-pax-system` offers it.
    package static let macSystemHash = Data(repeating: 0xB2, count: 32)
    /// The 2.5 MiB EXECUTABLE payload `host-exec-2.5m` offers.
    package static let executableTag: UInt64 = 25
    package static let executableSize = 2_621_440
    /// The payload `host-stale` offers first, then replaces with an unsupported format.
    package static let staleTag: UInt64 = 26

    package static func host(_ name: String) -> HostConfiguration? {
        var bundles: [BundledPayload] = []
        var protocolVersion: UInt32 = 1
        switch name {
        case "host-default":
            break
        case "host-pax-system":
            bundles = [
                BundledPayload(
                    os: .macOS, architecture: .arm64, scope: .system,
                    manifest: UpdateManifestValue(
                        payloadHash: macSystemHash, payloadSize: 48_000_000, format: .paxTree, versionLabel: "2.0"))
            ]
        case "host-exec-2.5m":
            bundles = [SimHub.bundle(size: executableSize, tag: executableTag)]
        case "host-stale":
            bundles = [SimHub.bundle(size: 100_000, tag: staleTag)]
        case "host-proto2":
            protocolVersion = 2
        default:
            return nil
        }
        var configuration = HostConfiguration(
            claim: PeerClaim(role: .host, versionLabel: "Kernova"), sessionToken: token,
            policy: PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)]), bundles: bundles)
        let version = protocolVersion
        configuration.tweak = { connection in
            connection.recordsTrace = true
            connection.protocolVersion = version
        }
        return configuration
    }

    /// The bundles a `setBundles fixture=<name>` input installs.
    package static func bundles(_ name: String) -> [BundledPayload]? {
        switch name {
        case "none": []
        case "stale-pax": [SimHub.bundle(size: 100_000, tag: staleTag + 1, format: .paxTree)]
        default: nil
        }
    }

    package static func peer(_ name: String) -> PeerConfiguration? {
        var protocolVersion: UInt32 = 1
        let configuration: PeerConfiguration
        switch name {
        case "linux-session-v1", "linux-session-proto2":
            protocolVersion = name == "linux-session-proto2" ? 2 : 1
            configuration = PeerConfiguration(
                claim: PeerClaim(
                    role: .sessionPeer, scope: .user, os: .linux, osVersion: "24.04", osBuild: "6.8.0",
                    osDistribution: "ubuntu", architecture: .arm64, payloadHash: linuxSessionHash, versionLabel: "2.0",
                    instanceID: Data(repeating: 0x5E, count: 16)),
                state: PeerSessionState(console: .on, sessionID: "c2", userName: "ada"),
                power: .available(PowerOffer(actions: [.shutdown, .restart], asksAppsToQuit: true)),
                logs: .available(NoParams()), update: .available(UpdateOffer(formats: [.executable])))
        case "macos-system-v1":
            configuration = PeerConfiguration(
                claim: PeerClaim(
                    role: .systemPeer, scope: .system, os: .macOS, osVersion: "15.3.1", osBuild: "24D70",
                    architecture: .arm64, payloadHash: macSystemHash, versionLabel: "2.0",
                    instanceID: Data(repeating: 0x5F, count: 16)),
                state: PeerSessionState(console: .on, consoleSessionID: "257"),
                power: .available(PowerOffer(actions: [.shutdown, .restart], asksAppsToQuit: true)),
                logs: .available(NoParams()), update: .available(UpdateOffer(formats: [.paxTree])))
        default:
            return nil
        }
        var tweaked = configuration
        let version = protocolVersion
        tweaked.tweak = { connection in
            connection.recordsTrace = true
            connection.protocolVersion = version
        }
        return tweaked
    }
}

/// One frozen frame as an `expect` line states it, and how the replay matches it.
package struct FrozenLine: Sendable, Equatable {
    /// How a replay may treat a produced frame the transcript does not expect next.
    package enum Match: Sendable, Equatable {
        /// Never skipped: the frame must be the next one expected, and none may be left over.
        case strict
        /// A stream-0 snapshot a non-frozen change may legitimately repeat; skipped when not expected.
        case tolerant
    }

    package var text: String
    package var match: Match

    package init(_ text: String, _ match: Match = .strict) {
        self.text = text
        self.match = match
    }
}

/// The frozen fields of a frame, as an `expect` line states them. Nil for frames
/// of non-frozen kinds and non-frozen session content, which the matcher never
/// sees. Frames on POWER_REQUEST and UPDATE_PULL streams, RESET(0) and the Hello
/// are strict; the stream-0 snapshots (capabilities, peer state, policy, the
/// update offer) are tolerant.
package enum FrozenFields {
    package static func describe(_ frame: Frame, kinds: [UInt32: StreamKind]) -> FrozenLine? {
        let id = frame.streamID.rawValue
        let prefix = "s=\(id)"
        switch frame.type {
        case .ping, .window:
            return nil
        case .reset:
            let error = (try? Kernova_V2_Error(serializedBytes: frame.payload)) ?? Kernova_V2_Error()
            if id == 0 {
                return FrozenLine("\(prefix) RESET code=\(error.code.rawValue) retry_after_ms=\(error.retryAfterMs)")
            }
            guard isFrozen(kinds[id]) else { return nil }
            return FrozenLine("\(prefix) RESET code=\(error.code.rawValue)")
        case .open:
            let open = (try? Kernova_V2_Open(serializedBytes: frame.payload)) ?? Kernova_V2_Open()
            switch open.kind {
            case .powerRequest:
                let body = (try? Kernova_V2_PowerRequest(serializedBytes: open.body)) ?? Kernova_V2_PowerRequest()
                return FrozenLine(
                    "\(prefix) OPEN kind=POWER_REQUEST body.action=\(body.action.rawValue) body.acceptance_deadline_ms=\(body.acceptanceDeadlineMs)"
                )
            case .updatePull:
                let body = (try? Kernova_V2_UpdatePull(serializedBytes: open.body)) ?? Kernova_V2_UpdatePull()
                return FrozenLine("\(prefix) OPEN kind=UPDATE_PULL body.payload_hash=\(hex(body.payloadHash))")
            default:
                return nil
            }
        case .end:
            switch kinds[id] {
            case .powerRequest:
                guard !frame.payload.isEmpty else { return FrozenLine("\(prefix) END empty") }
                let outcome =
                    (try? Kernova_V2_PowerOutcome(serializedBytes: frame.payload)) ?? Kernova_V2_PowerOutcome()
                return FrozenLine(
                    "\(prefix) END outcome.kind=\(outcome.kind.rawValue) outcome.code=\(outcome.error.code.rawValue) outcome.apps=\(apps(outcome.apps))"
                )
            case .updatePull:
                guard !frame.payload.isEmpty else { return FrozenLine("\(prefix) END empty") }
                let result = (try? Kernova_V2_UpdateResult(serializedBytes: frame.payload)) ?? Kernova_V2_UpdateResult()
                return FrozenLine(
                    "\(prefix) END result.kind=\(result.kind.rawValue) result.code=\(result.error.code.rawValue)")
            default:
                return nil
            }
        case .data:
            guard frame.flags.contains(.message) else { return nil }
            if id == 0 { return session(frame.payload) }
            guard kinds[id] == .powerRequest else { return nil }
            let progress = (try? Kernova_V2_PowerProgress(serializedBytes: frame.payload)) ?? Kernova_V2_PowerProgress()
            return FrozenLine(
                "\(prefix) MSG progress.stage=\(progress.stage.rawValue) progress.apps=\(apps(progress.apps))")
        }
    }

    static func isFrozen(_ kind: StreamKind?) -> Bool {
        kind == .powerRequest || kind == .updatePull
    }

    static func session(_ payload: Data) -> FrozenLine? {
        guard let message = try? Kernova_V2_SessionMessage(serializedBytes: payload) else {
            return FrozenLine("s=0 MSG undecodable")
        }
        switch message.message {
        case .hello(let hello):
            let identity = hello.identity
            var text = "s=0 MSG hello role=\(identity.role.rawValue) scope=\(identity.installScope.rawValue)"
            if identity.role != .host {
                text += " os=\(identity.os.rawValue) arch=\(identity.architecture.rawValue)"
                text += " payload_hash=\(hex(identity.payloadHash)) instance_id=\(hex(identity.instanceID))"
                text += " state=\(state(hello.state))"
            } else {
                text += " token=\(hex(hello.sessionToken))"
            }
            return FrozenLine(text + " " + adverts(hello.features))
        case .peerState(let peerState):
            return FrozenLine("s=0 MSG peer_state \(state(peerState))", .tolerant)
        case .capabilities(let update):
            return FrozenLine("s=0 MSG capabilities " + adverts(update.features), .tolerant)
        case .policy:
            return FrozenLine("s=0 MSG policy", .tolerant)
        case .updateAvailable(let available):
            guard available.hasManifest else { return FrozenLine("s=0 MSG update_available none", .tolerant) }
            let manifest = available.manifest
            return FrozenLine(
                "s=0 MSG update_available hash=\(hex(manifest.payloadHash)) size=\(manifest.payloadSize) format=\(manifest.format.rawValue) label=\(manifest.versionLabel)",
                .tolerant)
        case .extension, nil:
            return nil
        }
    }

    static func state(_ state: Kernova_V2_PeerState) -> String {
        "console=\(state.console.rawValue),session=\(state.sessionID),user=\(state.userName),console_session=\(state.consoleSessionID)"
    }

    /// The frozen features' adverts: POWER and UPDATE.
    static func adverts(_ features: [Kernova_V2_FeatureAdvert]) -> String {
        [FeatureID.power, .update].map { feature -> String in
            guard let advert = features.first(where: { $0.feature == feature }) else {
                return "\(feature.rawValue)=unlisted"
            }
            switch advert.availability {
            case .params(let params):
                if feature == .power {
                    let capability =
                        (try? Kernova_V2_PowerCapability(serializedBytes: params)) ?? Kernova_V2_PowerCapability()
                    return
                        "\(feature.rawValue)=v\(advert.version):actions[\(capability.actions.map { "\($0.rawValue)" }.joined(separator: ","))]:asks=\(capability.asksAppsToQuit)"
                }
                let capability =
                    (try? Kernova_V2_UpdateCapability(serializedBytes: params)) ?? Kernova_V2_UpdateCapability()
                return
                    "\(feature.rawValue)=v\(advert.version):formats[\(capability.formats.map { "\($0.rawValue)" }.joined(separator: ","))]"
            case .absent(let absence):
                return "\(feature.rawValue)=v\(advert.version):absent=\(absence.reason.rawValue)"
            case nil:
                return "\(feature.rawValue)=v\(advert.version):none"
            }
        }.joined(separator: " ")
    }

    static func apps(_ apps: [Kernova_V2_BlockingApp]) -> String {
        "[" + apps.map(\.displayName).joined(separator: ",") + "]"
    }

    package static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    package static func unhex(_ text: Substring) -> Data? {
        var data = Data(capacity: text.utf8.count / 2)
        var high: UInt8?
        for character in text.utf8 {
            let value: UInt8
            switch character {
            case 0x30...0x39: value = character - 0x30
            case 0x61...0x66: value = character - 0x61 + 10
            case 0x41...0x46: value = character - 0x41 + 10
            case 0x20: continue
            default: return nil
            }
            if let pending = high {
                data.append(pending << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return high == nil ? data : nil
    }
}

/// The fixtures' payload source: serves each read from the content of the
/// manifest it names; the server ends the pull at the manifest's size.
package struct FixturePayloadSource: Sendable {
    /// Each manifest's content, by payload hash, generated once.
    private var contents: [Data: Data] = [:]

    package init() {}

    /// The answer to `effect`.
    package mutating func answer(_ effect: HostEffect) -> PayloadInput {
        switch effect {
        case .read(let id, let manifest, let offset, let maxBytes):
            let content = contents[manifest.payloadHash] ?? SimHub.expectedContent(manifest)
            contents[manifest.payloadHash] = content
            return .bytes(id, Self.read(content, offset: offset, maxBytes: maxBytes))
        }
    }

    /// Up to `maxBytes` of `content` from `offset`: empty past its end.
    package static func read(_ content: Data, offset: UInt64, maxBytes: Int) -> Data {
        let start = content.startIndex + Int(clamping: min(offset, UInt64(content.count)))
        return content.subdata(in: start..<min(start + maxBytes, content.endIndex))
    }
}
