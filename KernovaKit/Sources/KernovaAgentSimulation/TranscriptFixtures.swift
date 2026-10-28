#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// The named configurations a transcript's header refers to (§10.5). A fixture
/// fixes every identity string, instance id, hash and advert; once a frozen
/// transcript names one, it never changes.
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

/// The frozen fields of a frame, as an `expect` line states them (§10.5). Nil for
/// frames of non-frozen kinds and non-frozen session content, which the matcher skips.
package enum FrozenFields {
    package static func describe(_ frame: Frame, kinds: [UInt32: StreamKind]) -> String? {
        let id = frame.streamID.rawValue
        let prefix = "s=\(id)"
        switch frame.type {
        case .ping, .window:
            return nil
        case .reset:
            let error = (try? Kernova_V2_Error(serializedBytes: frame.payload)) ?? Kernova_V2_Error()
            if id == 0 { return "\(prefix) RESET code=\(error.code.rawValue) retry_after_ms=\(error.retryAfterMs)" }
            guard isFrozen(kinds[id]) else { return nil }
            return "\(prefix) RESET code=\(error.code.rawValue)"
        case .open:
            let open = (try? Kernova_V2_Open(serializedBytes: frame.payload)) ?? Kernova_V2_Open()
            switch open.kind {
            case .powerRequest:
                let body = (try? Kernova_V2_PowerRequest(serializedBytes: open.body)) ?? Kernova_V2_PowerRequest()
                return
                    "\(prefix) OPEN kind=POWER_REQUEST body.action=\(body.action.rawValue) body.acceptance_deadline_ms=\(body.acceptanceDeadlineMs)"
            case .updatePull:
                let body = (try? Kernova_V2_UpdatePull(serializedBytes: open.body)) ?? Kernova_V2_UpdatePull()
                return "\(prefix) OPEN kind=UPDATE_PULL body.payload_hash=\(hex(body.payloadHash))"
            default:
                return nil
            }
        case .end:
            switch kinds[id] {
            case .powerRequest:
                guard !frame.payload.isEmpty else { return "\(prefix) END empty" }
                let outcome =
                    (try? Kernova_V2_PowerOutcome(serializedBytes: frame.payload)) ?? Kernova_V2_PowerOutcome()
                return
                    "\(prefix) END outcome.kind=\(outcome.kind.rawValue) outcome.code=\(outcome.error.code.rawValue) outcome.apps=\(apps(outcome.apps))"
            case .updatePull:
                guard !frame.payload.isEmpty else { return "\(prefix) END empty" }
                let result = (try? Kernova_V2_UpdateResult(serializedBytes: frame.payload)) ?? Kernova_V2_UpdateResult()
                return "\(prefix) END result.kind=\(result.kind.rawValue) result.code=\(result.error.code.rawValue)"
            default:
                return nil
            }
        case .data:
            guard frame.flags.contains(.message) else { return nil }
            if id == 0 { return session(frame.payload) }
            guard kinds[id] == .powerRequest else { return nil }
            let progress = (try? Kernova_V2_PowerProgress(serializedBytes: frame.payload)) ?? Kernova_V2_PowerProgress()
            return "\(prefix) MSG progress.stage=\(progress.stage.rawValue) progress.apps=\(apps(progress.apps))"
        }
    }

    static func isFrozen(_ kind: StreamKind?) -> Bool {
        kind == .powerRequest || kind == .updatePull
    }

    static func session(_ payload: Data) -> String? {
        guard let message = try? Kernova_V2_SessionMessage(serializedBytes: payload) else {
            return "s=0 MSG undecodable"
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
            return text + " " + adverts(hello.features)
        case .peerState(let peerState):
            return "s=0 MSG peer_state \(state(peerState))"
        case .capabilities(let update):
            return "s=0 MSG capabilities " + adverts(update.features)
        case .policy:
            return "s=0 MSG policy"
        case .updateAvailable(let available):
            guard available.hasManifest else { return "s=0 MSG update_available none" }
            let manifest = available.manifest
            return
                "s=0 MSG update_available hash=\(hex(manifest.payloadHash)) size=\(manifest.payloadSize) format=\(manifest.format.rawValue) label=\(manifest.versionLabel)"
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

/// The fixtures' payload source: serves each pull the content of the manifest it
/// pulls, a read at a time, then finishes.
package struct FixturePayloadSource: Sendable {
    private var sent: [UpdatePullID: Int] = [:]
    private var manifests: [UpdatePullID: UpdateManifestValue] = [:]
    private var contents: [UpdatePullID: Data] = [:]

    package init() {}

    /// The commands answering `event`, if it is an update event.
    package mutating func answer(_ event: HostEvent) -> [HostCommand] {
        switch event {
        case .update(.pullRequested(let id, let manifest)):
            manifests[id] = manifest
            contents[id] = SimHub.expectedContent(manifest)
            sent[id] = 0
            return []
        case .update(.writable(let id, let maxBytes)):
            guard manifests[id] != nil, let content = contents[id], let offset = sent[id] else { return [] }
            let count = min(maxBytes, content.count - offset)
            sent[id] = offset + count
            var commands: [HostCommand] = []
            if count > 0 { commands.append(.updateBytes(id, content.subdata(in: offset..<(offset + count)))) }
            if offset + count == content.count {
                commands.append(.updateFinished(id))
                manifests[id] = nil
                contents[id] = nil
            }
            return commands
        default:
            return []
        }
    }
}
