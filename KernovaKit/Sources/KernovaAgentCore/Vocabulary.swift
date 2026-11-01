#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// Which item an operation failed on: the domain form of `ItemFailure`.
public struct ItemFailureValue: Sendable, Equatable {
    /// The item's path as byte components, its own name first.
    public var path: [Data]
    /// The errno the OS call failed with; 0 when none.
    public var posixErrno: Int32
    /// The item ended before the size its header declared.
    public var endedEarly: Bool

    /// Creates an item failure.
    public init(path: [Data], posixErrno: Int32 = 0, endedEarly: Bool = false) {
        self.path = path
        self.posixErrno = posixErrno
        self.endedEarly = endedEarly
    }
}

/// The domain form of the wire's `Error`: a RESET's payload, or an outcome's error.
public struct WireError: Error, Sendable, Equatable {
    /// What went wrong.
    public var code: ErrorCode
    /// The item, for READ_FAILED and WRITE_FAILED.
    public var item: ItemFailureValue?
    /// The errno an OS call failed with; 0 when none.
    public var posixErrno: Int32
    /// TOO_LARGE: the limit, in bytes.
    public var limit: UInt64
    /// FEATURE_UNAVAILABLE: why.
    public var absence: AbsenceReason
    /// On a connection close only: how long the receiver waits before dialing again.
    public var retryAfter: CoreDuration?
    /// Text for the receiver's log; never shown in UI.
    public var debugDetail: String

    /// Creates an error carrying `code` and whichever details apply.
    public init(
        _ code: ErrorCode, item: ItemFailureValue? = nil, posixErrno: Int32 = 0, limit: UInt64 = 0,
        absence: AbsenceReason = .unspecified, retryAfter: CoreDuration? = nil, debugDetail: String = ""
    ) {
        self.code = code
        self.item = item
        self.posixErrno = posixErrno
        self.limit = limit
        self.absence = absence
        self.retryAfter = retryAfter
        self.debugDetail = debugDetail
    }
}

/// Whether a feature is offered, with its parameters, or why not.
public enum Availability<Params: Sendable & Equatable>: Sendable, Equatable {
    /// Offered, with the feature's parameters.
    case available(Params)
    /// Not offered, and why.
    case absent(AbsenceReason, debugDetail: String)

    /// Whether the feature is offered.
    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// The parameters, when offered.
    public var params: Params? {
        if case .available(let params) = self { return params }
        return nil
    }
}

/// A feature with no parameters of its own.
public struct NoParams: Sendable, Equatable {
    /// The one value.
    public init() {}
}

/// One feature as this side advertises it: its version and availability, with
/// the capability message encoded.
public struct LocalAdvert: Sendable, Equatable {
    /// The feature's exact-match version.
    public var version: UInt32
    /// Offered with the encoded capability message, or absent.
    public var availability: Availability<Data>

    /// Creates an advert.
    public init(version: UInt32, availability: Availability<Data>) {
        self.version = version
        self.availability = availability
    }
}

/// One status per feature, ordered by the feature's raw value.
public struct FeatureStatusTable: Sendable, Equatable {
    /// The table's rows, in feature order.
    public private(set) var entries: [(feature: FeatureID, status: Availability<Data>)]

    /// Creates a table from rows in any order; a repeated feature keeps its first row.
    public init(_ rows: [(feature: FeatureID, status: Availability<Data>)] = []) {
        var sorted: [(feature: FeatureID, status: Availability<Data>)] = []
        for row in rows where !sorted.contains(where: { $0.feature == row.feature }) {
            sorted.append(row)
        }
        sorted.sort { $0.feature.rawValue < $1.feature.rawValue }
        entries = sorted
    }

    /// The feature's status; an unlisted feature is absent, `NOT_IMPLEMENTED`.
    public subscript(_ feature: FeatureID) -> Availability<Data> {
        entries.first { $0.feature == feature }?.status ?? .absent(.notImplemented, debugDetail: "")
    }

    /// Tables are equal when their rows are.
    public static func == (lhs: FeatureStatusTable, rhs: FeatureStatusTable) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.feature == $1.feature && $0.status == $1.status }
    }
}

/// One side's role on a connection.
public enum PeerRole: Sendable, Equatable {
    /// Kernova's side.
    case host
    /// The agent of one GUI session.
    case sessionPeer
    /// The agent of the guest as a whole.
    case systemPeer
}

/// Where an agent is installed.
public enum InstallScope: Int, Sendable, Equatable {
    /// The host, or a development build run in place.
    case unspecified = 0
    /// One user's install.
    case user = 1
    /// The guest's system-wide install.
    case system = 2
}

/// The guest operating system's family.
public enum OSFamily: Int, Sendable, Equatable {
    /// Not stated.
    case unspecified = 0
    /// macOS.
    case macOS = 1
    /// Linux.
    case linux = 2
    /// Windows.
    case windows = 3
}

/// A CPU architecture.
public enum Architecture: Int, Sendable, Equatable {
    /// Not stated.
    case unspecified = 0
    /// 64-bit ARM.
    case arm64 = 1
    /// x86-64.
    case x86_64 = 2
}

/// Who a side claims to be: a normalized `PeerIdentity`.
public struct PeerClaim: Sendable, Equatable {
    /// The claimed role.
    public var role: PeerRole
    /// The claimed install scope.
    public var scope: InstallScope
    /// The guest OS family.
    public var os: OSFamily
    /// The OS version, as the OS spells it.
    public var osVersion: String
    /// The OS build.
    public var osBuild: String
    /// Linux only: the os-release ID.
    public var osDistribution: String
    /// The CPU architecture.
    public var architecture: Architecture
    /// SHA-256 of the update payload this install came from; empty when none.
    public var payloadHash: Data
    /// The display version.
    public var versionLabel: String
    /// 16 random bytes drawn once per process start; empty matches nothing.
    public var instanceID: Data

    /// Creates a claim.
    public init(
        role: PeerRole, scope: InstallScope = .unspecified, os: OSFamily = .unspecified, osVersion: String = "",
        osBuild: String = "", osDistribution: String = "", architecture: Architecture = .unspecified,
        payloadHash: Data = Data(), versionLabel: String = "", instanceID: Data = Data()
    ) {
        self.role = role
        self.scope = scope
        self.os = os
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.osDistribution = osDistribution
        self.architecture = architecture
        self.payloadHash = payloadHash
        self.versionLabel = versionLabel
        self.instanceID = instanceID
    }
}

/// Whether a peer's session owns the guest's console.
public enum ConsoleState: Int, Sendable, Equatable {
    /// Not known.
    case unknown = 0
    /// Session peer: its session owns the console. System peer: a user session does.
    case on = 1
    /// Session peer: switched out, remote or locked out. System peer: no user session owns it.
    case off = 2
}

/// A peer's place in the guest's sessions: a normalized `PeerState`.
public struct PeerSessionState: Sendable, Equatable {
    /// Console ownership as the peer reports it.
    public var console: ConsoleState
    /// Session peer: its own session's identifier; fixed for the connection.
    public var sessionID: String
    /// Session peer: the session user's login name.
    public var userName: String
    /// System peer: the session that owns the console when `console` is `.on`.
    public var consoleSessionID: String

    /// Creates a state.
    public init(
        console: ConsoleState = .unknown, sessionID: String = "", userName: String = "", consoleSessionID: String = ""
    ) {
        self.console = console
        self.sessionID = sessionID
        self.userName = userName
        self.consoleSessionID = consoleSessionID
    }
}

/// Which connection of a process an id belongs to.
public struct ConnectionGeneration: Hashable, Comparable, Sendable {
    /// The generation's number.
    public var rawValue: UInt64

    /// Creates the generation `rawValue` names.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Orders generations by number.
    public static func < (lhs: ConnectionGeneration, rhs: ConnectionGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One power request: the hub's id on the host, the stream's on the peer.
public struct PowerRequestID: Hashable, Sendable {
    /// The connection the request belongs to.
    public var generation: ConnectionGeneration
    /// The request's number within it.
    public var rawValue: UInt64

    /// Creates a request id.
    public init(generation: ConnectionGeneration, rawValue: UInt64) {
        self.generation = generation
        self.rawValue = rawValue
    }
}

/// One update pull: the connection and the stream carrying it.
public struct UpdatePullID: Hashable, Sendable {
    /// The connection the pull belongs to.
    public var generation: ConnectionGeneration
    /// The pull's stream.
    public var stream: StreamID

    /// Creates a pull id.
    public init(generation: ConnectionGeneration, stream: StreamID) {
        self.generation = generation
        self.stream = stream
    }
}

/// One policy-governed feature's setting.
public struct FeaturePolicyValue: Sendable, Equatable {
    /// The feature.
    public var feature: FeatureID
    /// The version `params` is encoded for.
    public var version: UInt32
    /// Whether the VM's settings turn it on.
    public var enabled: Bool
    /// The feature's policy message, encoded.
    public var params: Data

    /// Creates a setting.
    public init(feature: FeatureID, version: UInt32 = 1, enabled: Bool, params: Data = Data()) {
        self.feature = feature
        self.version = version
        self.enabled = enabled
        self.params = params
    }
}

/// A full snapshot of the policy-governed features' settings, in feature order.
public struct PolicySnapshot: Sendable, Equatable {
    /// One entry per listed feature; a governed feature not listed is disabled.
    public private(set) var entries: [FeaturePolicyValue]

    /// Creates a snapshot; a repeated feature keeps its first entry.
    public init(_ entries: [FeaturePolicyValue] = []) {
        var kept: [FeaturePolicyValue] = []
        for entry in entries where !kept.contains(where: { $0.feature == entry.feature }) {
            kept.append(entry)
        }
        kept.sort { $0.feature.rawValue < $1.feature.rawValue }
        self.entries = kept
    }

    /// Whether the snapshot enables `feature`.
    public func isEnabled(_ feature: FeatureID) -> Bool {
        entries.first { $0.feature == feature }?.enabled ?? false
    }
}

/// What one bundled update payload is.
public struct UpdateManifestValue: Sendable, Equatable {
    /// SHA-256 of the payload.
    public var payloadHash: Data
    /// The payload's size in bytes.
    public var payloadSize: UInt64
    /// How the payload is packaged.
    public var format: PayloadFormat
    /// The display version it installs.
    public var versionLabel: String

    /// Creates a manifest.
    public init(payloadHash: Data, payloadSize: UInt64, format: PayloadFormat, versionLabel: String = "") {
        self.payloadHash = payloadHash
        self.payloadSize = payloadSize
        self.format = format
        self.versionLabel = versionLabel
    }
}

/// One payload the host bundles, keyed by what it installs onto.
public struct BundledPayload: Sendable, Equatable {
    /// The OS family it installs on.
    public var os: OSFamily
    /// The architecture it installs on.
    public var architecture: Architecture
    /// The install scope it updates.
    public var scope: InstallScope
    /// What the payload is.
    public var manifest: UpdateManifestValue

    /// Creates a bundled payload.
    public init(os: OSFamily, architecture: Architecture, scope: InstallScope, manifest: UpdateManifestValue) {
        self.os = os
        self.architecture = architecture
        self.scope = scope
        self.manifest = manifest
    }

    /// What the host offers a peer claiming `claim`: a session peer of USER
    /// scope its os and architecture's USER bundle, a system peer the SYSTEM bundle,
    /// anything else nothing. The first matching bundle wins.
    public static func offer(from bundles: [BundledPayload], for claim: PeerClaim) -> UpdateManifestValue? {
        let scope: InstallScope
        switch (claim.role, claim.scope) {
        case (.sessionPeer, .user): scope = .user
        case (.systemPeer, .system): scope = .system
        default: return nil
        }
        return bundles.first { $0.scope == scope && $0.os == claim.os && $0.architecture == claim.architecture }?
            .manifest
    }
}

/// An app the guest reports as holding a power request.
public struct AppValue: Sendable, Equatable {
    /// The app's display name.
    public var displayName: String
    /// Its bundle identifier, desktop-file id or executable name.
    public var identifier: String
    /// Its process id.
    public var processID: Int32

    /// Creates an app.
    public init(displayName: String, identifier: String = "", processID: Int32 = 0) {
        self.displayName = displayName
        self.identifier = identifier
        self.processID = processID
    }
}

/// What a peer's power adapter can do now: the `PowerCapability` it advertises.
///
/// Two offers in one: `actions` wait for the apps that block them, `skippingBlockers` do not. A peer
/// offering only the second advertises POWER available with no `actions`, and `actionsAbsence` says why.
public struct PowerOffer: Sendable, Equatable {
    /// The actions it can perform now.
    public var actions: [PowerAction]
    /// Whether it asks running apps to quit.
    public var asksAppsToQuit: Bool
    /// The actions it can perform now without waiting for the apps that block them.
    public var skippingBlockers: [PowerAction]
    /// Why `actions` is empty; `nil` while it is not.
    public var actionsAbsence: AbsenceReason?

    /// Creates an offer.
    public init(
        actions: [PowerAction], asksAppsToQuit: Bool = false, skippingBlockers: [PowerAction] = [],
        actionsAbsence: AbsenceReason? = nil
    ) {
        self.actions = actions
        self.asksAppsToQuit = asksAppsToQuit
        self.skippingBlockers = skippingBlockers
        self.actionsAbsence = actionsAbsence
    }

    /// The actions offered in `skippingBlockers` mode: that list, or `actions`.
    public func actions(skippingBlockers skipping: Bool) -> [PowerAction] {
        skipping ? skippingBlockers : actions
    }

    /// POWER's `status` as the actions that wait for blocking apps see it: absent for the offer's
    /// `actionsAbsence` when it lists none of them, else `status` itself.
    public static func waitingStatus(_ status: Availability<Data>) -> Availability<Data> {
        guard let params = status.params, let offer = PowerOffer(params: params), offer.actions.isEmpty else {
            return status
        }
        return .absent(offer.actionsAbsence ?? .unspecified, debugDetail: "")
    }
}

/// What a peer's installer accepts, and the install's rejected hash.
public struct UpdateOffer: Sendable, Equatable {
    /// The formats it installs.
    public var formats: [PayloadFormat]
    /// The hash the install's slot metadata records as rejected, if any.
    public var rejectedHash: Data?

    /// Creates an offer.
    public init(formats: [PayloadFormat], rejectedHash: Data? = nil) {
        self.formats = formats
        self.rejectedHash = rejectedHash
    }
}

/// A liveness verdict about the far side, edge-triggered.
public enum LivenessChange: Sendable, Equatable {
    /// Silence crossed the unresponsive threshold.
    case unresponsive(silentFor: CoreDuration)
    /// A frame arrived after an unresponsive verdict.
    case responsive
}

/// How a stream ended.
public enum StreamClosure: Sendable, Equatable {
    /// Both sides sent END; the far side's END body.
    case completed(remoteEndBody: Data)
    /// The far side reset it.
    case resetByPeer(WireError)
    /// This side reset it.
    case resetLocally(WireError)
    /// This side closed the connection.
    case connectionClosedLocally(WireError)
    /// The far side closed the connection.
    case connectionClosedByPeer(WireError)
    /// The transport ended.
    case connectionLost
}

/// How a connection ended.
public enum ConnectionClosure: Sendable, Equatable {
    /// This side closed it, by command or on a fatal error, with this RESET(0).
    case closedLocally(WireError)
    /// The far side's RESET(0).
    case closedByPeer(WireError)
    /// The transport ended without a RESET(0).
    case transportLost
    /// The far side's first bytes were not the preamble; closed with no RESET.
    case notThisProtocol
}

extension ConnectionClosure {
    /// The RESET(0)'s error, or what ended the connection without one.
    var error: WireError {
        switch self {
        case .closedLocally(let error), .closedByPeer(let error): error
        case .transportLost: WireError(.unspecified, debugDetail: "the transport ended")
        case .notThisProtocol: WireError(.unspecified, debugDetail: "the far side does not speak this protocol")
        }
    }
}

/// A connection's phase.
public enum ConnectionState: Sendable, Equatable {
    /// The far side's Hello has not been read.
    case handshaking
    /// Both Hellos exchanged.
    case established
    /// A RESET(0) is queued; waiting for it to be handed out.
    case closing
    /// Nothing more happens; the driver releases the transport.
    case finished
}

/// How loud a diagnostic is.
public enum DiagnosticLevel: Sendable, Equatable {
    /// Something the far side did that the core tolerated.
    case notice
    /// A local component misbehaved.
    case error
}

/// A rate-limited note for the runtime's log; never behavior.
public enum Diagnostic: Sendable, Equatable {
    /// The far side broke a rule the core answered without closing the connection.
    case remoteViolation(String)
    /// A local component (an adapter, the hub) reported out of order or misused the core.
    case localFault(String)
    /// This many diagnostics were dropped in the last minute.
    case suppressed(Int)

    /// The level the runtime logs it at.
    public var level: DiagnosticLevel {
        switch self {
        case .remoteViolation, .suppressed: .notice
        case .localFault: .error
        }
    }
}
