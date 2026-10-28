#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf

// Generated messages stay inside the core: these convert at its edge, applying
// the receiver's normalization (§4.1) on the way in.

extension SwiftProtobuf.Message {
    /// The message's encoding; the generated messages hold no maps and no
    /// required fields, so encoding cannot fail.
    var encoded: Data {
        (try? serializedBytes()) ?? Data()
    }
}

extension WireError {
    var proto: Kernova_V2_Error {
        var error = Kernova_V2_Error()
        error.code = code
        if let item {
            var failure = Kernova_V2_ItemFailure()
            failure.path = item.path
            failure.posixErrno = item.posixErrno
            failure.endedEarly = item.endedEarly
            error.item = failure
        }
        error.posixErrno = posixErrno
        error.limit = limit
        error.absence = absence
        if let retryAfter, retryAfter.nanoseconds > 0 {
            error.retryAfterMs = UInt64(retryAfter.milliseconds)
        }
        error.debugDetail = Normalize.clip(debugDetail, maxBytes: Normalize.debugDetailBytes)
        return error
    }

    /// The received form: strings clipped, the code kept as sent.
    init(received error: Kernova_V2_Error) {
        self.init(
            error.code,
            item: error.hasItem
                ? ItemFailureValue(
                    path: error.item.path, posixErrno: error.item.posixErrno, endedEarly: error.item.endedEarly)
                : nil,
            posixErrno: error.posixErrno, limit: error.limit, absence: Self.absenceReceived(error.absence),
            retryAfter: error.retryAfterMs > 0
                ? .milliseconds(Int64(clamping: error.retryAfterMs)) : nil,
            debugDetail: Normalize.display(error.debugDetail, maxBytes: Normalize.debugDetailBytes))
    }

    /// Decodes a RESET or outcome payload; an undecodable one reads as UNSPECIFIED.
    init(receivedPayload payload: Data) {
        if let error = try? Kernova_V2_Error(serializedBytes: payload) {
            self.init(received: error)
        } else {
            self.init(.unspecified, debugDetail: "undecodable Error payload")
        }
    }

    static func absenceReceived(_ reason: AbsenceReason) -> AbsenceReason {
        switch reason {
        case .UNRECOGNIZED: .unspecified
        default: reason
        }
    }
}

extension ErrorCode {
    /// Whether this build's schema assigns the code: the generated
    /// `init(rawValue:)` never fails, mapping every other value to `.UNRECOGNIZED`.
    var isAssigned: Bool {
        if case .UNRECOGNIZED = self { return false }
        return true
    }
}

extension PeerRole {
    var proto: Kernova_V2_PeerIdentity.Role {
        switch self {
        case .host: .host
        case .sessionPeer: .sessionPeer
        case .systemPeer: .systemPeer
        }
    }
}

extension PeerClaim {
    var proto: Kernova_V2_PeerIdentity {
        var identity = Kernova_V2_PeerIdentity()
        identity.role = role.proto
        identity.installScope = Kernova_V2_PeerIdentity.InstallScope(rawValue: scope.rawValue) ?? .unspecified
        identity.os = Kernova_V2_PeerIdentity.OsFamily(rawValue: os.rawValue) ?? .unspecified
        identity.osVersion = osVersion
        identity.osBuild = osBuild
        identity.osDistribution = osDistribution
        identity.architecture = Kernova_V2_PeerIdentity.Architecture(rawValue: architecture.rawValue) ?? .unspecified
        identity.payloadHash = payloadHash
        identity.versionLabel = versionLabel
        identity.instanceID = instanceID
        return identity
    }

    /// The normalized claim, or nil when the role is not one any side accepts.
    init?(received identity: Kernova_V2_PeerIdentity) {
        let role: PeerRole
        switch identity.role {
        case .host: role = .host
        case .sessionPeer: role = .sessionPeer
        case .systemPeer: role = .systemPeer
        case .unspecified, .UNRECOGNIZED: return nil
        }
        let bytes = Normalize.identityStringBytes
        self.init(
            role: role,
            scope: InstallScope(rawValue: identity.installScope.rawValue) ?? .unspecified,
            os: OSFamily(rawValue: identity.os.rawValue) ?? .unspecified,
            osVersion: Normalize.display(identity.osVersion, maxBytes: bytes),
            osBuild: Normalize.display(identity.osBuild, maxBytes: bytes),
            osDistribution: Normalize.display(identity.osDistribution, maxBytes: bytes),
            architecture: Architecture(rawValue: identity.architecture.rawValue) ?? .unspecified,
            payloadHash: Normalize.clip(identity.payloadHash, maxBytes: Normalize.hashBytes),
            versionLabel: Normalize.display(identity.versionLabel, maxBytes: bytes),
            instanceID: identity.instanceID.count == Normalize.instanceIDBytes ? Data(identity.instanceID) : Data())
    }
}

extension PeerSessionState {
    var proto: Kernova_V2_PeerState {
        var state = Kernova_V2_PeerState()
        state.console = Kernova_V2_PeerState.Console(rawValue: console.rawValue) ?? .unknown
        state.sessionID = sessionID
        state.userName = userName
        state.consoleSessionID = consoleSessionID
        return state
    }

    init(received state: Kernova_V2_PeerState) {
        let bytes = Normalize.identityStringBytes
        self.init(
            console: ConsoleState(rawValue: state.console.rawValue) ?? .unknown,
            sessionID: Normalize.display(state.sessionID, maxBytes: bytes),
            userName: Normalize.display(state.userName, maxBytes: bytes),
            consoleSessionID: Normalize.display(state.consoleSessionID, maxBytes: bytes))
    }
}

extension UpdateManifestValue {
    var proto: Kernova_V2_UpdateManifest {
        var manifest = Kernova_V2_UpdateManifest()
        manifest.payloadHash = payloadHash
        manifest.payloadSize = payloadSize
        manifest.format = format
        manifest.versionLabel = versionLabel
        return manifest
    }

    init(received manifest: Kernova_V2_UpdateManifest) {
        self.init(
            payloadHash: Normalize.clip(manifest.payloadHash, maxBytes: Normalize.hashBytes),
            payloadSize: manifest.payloadSize, format: manifest.format,
            versionLabel: Normalize.display(manifest.versionLabel, maxBytes: Normalize.identityStringBytes))
    }
}

extension AppValue {
    static let maxCount = 32
    static let displayNameBytes = 128
    static let identifierBytes = 256

    /// The app within the wire's bounds, as the receiver normalizes it; the
    /// sender applies it too, so `maxCount` apps always fit one message.
    var normalized: AppValue {
        AppValue(
            displayName: Normalize.display(displayName, maxBytes: Self.displayNameBytes),
            identifier: Normalize.display(identifier, maxBytes: Self.identifierBytes), processID: processID)
    }

    var proto: Kernova_V2_BlockingApp {
        let normalized = normalized
        var app = Kernova_V2_BlockingApp()
        app.displayName = normalized.displayName
        app.identifier = normalized.identifier
        app.processID = normalized.processID
        return app
    }

    init(received app: Kernova_V2_BlockingApp) {
        self = AppValue(displayName: app.displayName, identifier: app.identifier, processID: app.processID).normalized
    }

    /// An apps list as sent: at most `maxCount`, each normalized.
    static func wire(_ apps: [AppValue]) -> [Kernova_V2_BlockingApp] {
        apps.prefix(maxCount).map(\.proto)
    }

    static func received(_ apps: [Kernova_V2_BlockingApp]) -> [AppValue] {
        apps.prefix(maxCount).map(AppValue.init(received:))
    }
}

extension PowerOffer {
    var encoded: Data {
        var capability = Kernova_V2_PowerCapability()
        capability.actions = actions
        capability.asksAppsToQuit = asksAppsToQuit
        return capability.encoded
    }

    /// Decodes a far side's `PowerCapability` params; nil when they do not decode.
    public init?(params: Data) {
        guard let capability = try? Kernova_V2_PowerCapability(serializedBytes: params) else { return nil }
        self.init(actions: capability.actions, asksAppsToQuit: capability.asksAppsToQuit)
    }
}

extension UpdateOffer {
    /// The advertised `UpdateCapability`; the rejected hash stays local.
    var encodedCapability: Data {
        var capability = Kernova_V2_UpdateCapability()
        capability.formats = formats
        return capability.encoded
    }
}
