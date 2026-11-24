#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One scripted input of a transcript, in its `in` line's text form.
package enum TranscriptInput: Sendable, Equatable {
    case host(HostCommand)
    case peer(PeerInput)
    /// The peer's installer reports on the pull the peer has open. The runner
    /// addresses it to the stream of the UPDATE_PULL OPEN it saw, so a script
    /// never names a stream id the current side chooses.
    case pull(PullReport)

    /// An installer's report on a pull.
    package enum PullReport: Sendable, Equatable {
        case installed
        case rejected(ErrorCode)

        func input(_ id: UpdatePullID) -> PeerInput {
            switch self {
            case .installed: .update(.installed(id))
            case .rejected(let code): .update(.rejected(id, WireError(code)))
            }
        }
    }

    static let generation = ConnectionGeneration(rawValue: 1)

    package var text: String {
        switch self {
        case .host(let command):
            switch command {
            case .requestPower(let id, let action, let ignoringApps):
                return "host requestPower id=\(id.rawValue) action=\(action.rawValue)"
                    + (ignoringApps ? " ignoreApps=1" : "")
            case .close(let code, let retry):
                return "host close code=\(code.rawValue) retry=\(retry?.milliseconds ?? 0)"
            case .setBundles(let bundles):
                return "host setBundles fixture=\(bundles.isEmpty ? "none" : "stale-pax")"
            default: return "host unsupported"
            }
        case .peer(let input):
            switch input {
            case .power(let power):
                switch power {
                case .accepted(let id): return "peer power accepted id=\(id.rawValue)"
                case .refused(let id, let error):
                    return "peer power refused id=\(id.rawValue) code=\(error.code.rawValue)"
                case .cancelled(let id): return "peer power cancelled id=\(id.rawValue)"
                case .unconfirmed(let id): return "peer power unconfirmed id=\(id.rawValue)"
                case .askingApps(let id): return "peer power askingApps id=\(id.rawValue)"
                case .waitingOnApps(let id, let apps):
                    return "peer power waitingOnApps id=\(id.rawValue) apps=\(Self.names(apps))"
                case .handedOff(let id): return "peer power handedOff id=\(id.rawValue)"
                case .blocked(let id, let apps): return "peer power blocked id=\(id.rawValue) apps=\(Self.names(apps))"
                case .cancelledInGuest(let id): return "peer power cancelledInGuest id=\(id.rawValue)"
                case .failed(let id, let error):
                    return "peer power failed id=\(id.rawValue) code=\(error.code.rawValue)"
                case .availability(.absent(let reason, _)): return "peer power absent reason=\(reason.rawValue)"
                case .availability(.available(let offer)):
                    return "peer power offer actions=\(offer.actions.map { "\($0.rawValue)" }.joined(separator: ","))"
                }
            case .peerState(let state):
                return "peer state console=\(state.console.rawValue) session=\(state.sessionID) user=\(state.userName)"
            default: return "peer unsupported"
            }
        case .pull(.installed):
            return "peer update installed"
        case .pull(.rejected(let code)):
            return "peer update rejected code=\(code.rawValue)"
        }
    }

    static func names(_ apps: [AppValue]) -> String {
        apps.map(\.displayName).joined(separator: ",")
    }

    /// Parses an `in` line's text.
    package init?(text: String) {
        let words = text.split(separator: " ")
        guard words.count >= 2 else { return nil }
        var fields: [String: String] = [:]
        for word in words.dropFirst(2) {
            let parts = word.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        func number(_ key: String) -> Int { fields[key].flatMap(Int.init) ?? 0 }
        func code(_ key: String) -> ErrorCode { ErrorCode(rawValue: number(key)) ?? .UNRECOGNIZED(number(key)) }
        let powerID = PowerRequestID(generation: Self.generation, rawValue: UInt64(number("id")))
        let apps = (fields["apps"] ?? "").split(separator: ",").map { AppValue(displayName: String($0)) }
        switch (words[0], words[1]) {
        case ("host", "requestPower"):
            self = .host(
                .requestPower(
                    powerID, PowerAction(rawValue: number("action")) ?? .unspecified,
                    ignoringApps: number("ignoreApps") == 1))
        case ("host", "close"):
            let retry = number("retry")
            self = .host(.close(code("code"), retryAfter: retry > 0 ? .milliseconds(Int64(retry)) : nil))
        case ("host", "setBundles"):
            guard let bundles = TranscriptFixture.bundles(fields["fixture"] ?? "") else { return nil }
            self = .host(.setBundles(bundles))
        case ("peer", "power"):
            guard words.count >= 3 else { return nil }
            let input: PowerInput
            switch words[2] {
            case "accepted": input = .accepted(powerID)
            case "refused": input = .refused(powerID, WireError(code("code")))
            case "cancelled": input = .cancelled(powerID)
            case "unconfirmed": input = .unconfirmed(powerID)
            case "askingApps": input = .askingApps(powerID)
            case "waitingOnApps": input = .waitingOnApps(powerID, apps)
            case "handedOff": input = .handedOff(powerID)
            case "blocked": input = .blocked(powerID, apps)
            case "cancelledInGuest": input = .cancelledInGuest(powerID)
            case "failed": input = .failed(powerID, WireError(code("code")))
            case "absent":
                input = .availability(
                    .absent(AbsenceReason(rawValue: number("reason")) ?? .unspecified, debugDetail: ""))
            case "offer":
                let actions = (fields["actions"] ?? "").split(separator: ",").compactMap {
                    Int($0).flatMap(PowerAction.init(rawValue:))
                }
                input = .availability(.available(PowerOffer(actions: actions, asksAppsToQuit: true)))
            default: return nil
            }
            self = .peer(.power(input))
        case ("peer", "update"):
            guard words.count >= 3 else { return nil }
            switch words[2] {
            case "installed": self = .pull(.installed)
            case "rejected": self = .pull(.rejected(code("code")))
            default: return nil
            }
        case ("peer", "state"):
            self = .peer(
                .peerState(
                    PeerSessionState(
                        console: ConsoleState(rawValue: number("console")) ?? .unknown,
                        sessionID: fields["session"] ?? "",
                        userName: fields["user"] ?? "")))
        default:
            return nil
        }
    }
}

/// The text of the events a transcript's `ev` lines name.
package enum TranscriptEvents {
    package static func describe(_ event: HostEvent) -> String? {
        switch event {
        case .role(.power(let id, let result)): "host power id=\(id.rawValue) \(describe(result))"
        case .role(.update(.result(_, let result))):
            "host update result kind=\(result.kind == .staged ? 1 : 2) code=\(result.error?.code.rawValue ?? 0)"
        case .role(.update(.closed(_, let closure))): "host update closed \(describe(closure))"
        case .closed(let closure): "host closed \(describe(closure))"
        default: nil
        }
    }

    package static func describe(_ effect: EndpointEffect<PeerRoleEffect>) -> String? {
        switch effect {
        case .role(.power(.perform(let id, let action, let ignoringApps))):
            "peer power perform id=\(id.rawValue) action=\(action.rawValue)\(ignoringApps ? " ignoreApps=1" : "")"
        case .role(.power(.cancel(let id))): "peer power cancel id=\(id.rawValue)"
        case .role(.update(.complete(let id, let manifest))):
            "peer update complete id=\(id.stream.rawValue) size=\(manifest.payloadSize)"
        case .role(.update(.recordRejected(let hash))): "peer update recordRejected hash=\(FrozenFields.hex(hash))"
        case .role(.update(.abort(let id))): "peer update abort id=\(id.stream.rawValue)"
        default: nil
        }
    }

    package static func describe(_ event: PeerEvent) -> String? {
        switch event {
        case .closed(let closure): "peer closed \(describe(closure))"
        default: nil
        }
    }

    static func describe(_ result: PowerRequestResult) -> String {
        switch result {
        case .accepted: "accepted"
        case .progress(let stage, let apps):
            "progress stage=\(stage == .askingApps ? 2 : 3) apps=\(TranscriptInput.names(apps))"
        case .refused(let error): "refused code=\(error.code.rawValue)"
        case .indeterminate: "indeterminate"
        case .finished(.handedOff): "finished handedOff"
        case .finished(.blocked(let apps)): "finished blocked apps=\(TranscriptInput.names(apps))"
        case .finished(.cancelledInGuest): "finished cancelledInGuest"
        case .finished(.failed(let error)): "finished failed code=\(error.code.rawValue)"
        case .lostAfterAcceptance: "lostAfterAcceptance"
        }
    }

    static func describe(_ closure: StreamClosure) -> String {
        switch closure {
        case .completed: "completed"
        case .resetByPeer(let error): "resetByPeer code=\(error.code.rawValue)"
        case .resetLocally(let error): "resetLocally code=\(error.code.rawValue)"
        case .connectionClosedLocally(let error): "connectionClosedLocally code=\(error.code.rawValue)"
        case .connectionClosedByPeer(let error): "connectionClosedByPeer code=\(error.code.rawValue)"
        case .connectionLost: "connectionLost"
        }
    }

    static func describe(_ closure: ConnectionClosure) -> String {
        switch closure {
        case .closedLocally(let error): "local code=\(error.code.rawValue) retry=\(error.retryAfter?.milliseconds ?? 0)"
        case .closedByPeer(let error): "byPeer code=\(error.code.rawValue) retry=\(error.retryAfter?.milliseconds ?? 0)"
        case .transportLost: "lost"
        case .notThisProtocol: "notThisProtocol"
        }
    }
}
