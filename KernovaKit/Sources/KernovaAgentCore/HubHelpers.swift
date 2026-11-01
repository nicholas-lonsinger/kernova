#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// The hub's handle on one connected peer.
public struct PeerHandle: Hashable, Comparable, Sendable {
    /// The hub's number for the connection.
    public var rawValue: UInt64

    /// Creates a handle.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Orders handles by number.
    public static func < (lhs: PeerHandle, rhs: PeerHandle) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Identity conflicts

/// The parts of a connection the conflict rule reads.
public struct ConflictParty: Sendable, Equatable {
    /// The peer's claim.
    public var claim: PeerClaim
    /// Its session state (the session id is part of a session peer's key).
    public var state: PeerSessionState
    /// Whether the host judges it unresponsive.
    public var isUnresponsive: Bool

    /// Creates a party.
    public init(claim: PeerClaim, state: PeerSessionState, isUnresponsive: Bool = false) {
        self.claim = claim
        self.state = state
        self.isUnresponsive = isUnresponsive
    }
}

/// Which connection of a conflicting pair closes, and how.
public enum ConflictResolution: Sendable, Equatable {
    /// Different identity keys: both stay.
    case noConflict
    /// The existing connection closes with `code`; the incoming stays.
    case closeExisting(ErrorCode, retryAfter: CoreDuration?)
    /// The incoming connection closes with `code`; the existing stays.
    case closeIncoming(ErrorCode, retryAfter: CoreDuration?)
}

/// The host's rule for two connections claiming one identity.
public enum PeerConflict {
    /// A lower-rank install stays quiet this long.
    public static let lowerRankRetry = CoreDuration.milliseconds(60_000)
    /// An equal-rank duplicate retries after this; it exceeds the 15 s unresponsive threshold.
    public static let duplicateRetry = CoreDuration.milliseconds(20_000)

    /// Whether the two claim the same identity key: the role, plus the session id
    /// for a session peer.
    public static func sameKey(_ a: ConflictParty, _ b: ConflictParty) -> Bool {
        guard a.claim.role == b.claim.role else { return false }
        return a.claim.role != .sessionPeer || a.state.sessionID == b.state.sessionID
    }

    /// How a second connection claiming `existing`'s identity is resolved.
    public static func resolve(existing: ConflictParty, incoming: ConflictParty) -> ConflictResolution {
        guard sameKey(existing, incoming) else { return .noConflict }
        if !existing.claim.instanceID.isEmpty, existing.claim.instanceID == incoming.claim.instanceID {
            return .closeExisting(.superseded, retryAfter: nil)
        }
        if existing.claim.role == .sessionPeer {
            let existingRank = rank(existing.claim.scope)
            let incomingRank = rank(incoming.claim.scope)
            if existingRank > incomingRank { return .closeIncoming(.duplicatePeer, retryAfter: lowerRankRetry) }
            if incomingRank > existingRank { return .closeExisting(.duplicatePeer, retryAfter: lowerRankRetry) }
        }
        if existing.isUnresponsive { return .closeExisting(.superseded, retryAfter: nil) }
        return .closeIncoming(.duplicatePeer, retryAfter: duplicateRetry)
    }

    static func rank(_ scope: InstallScope) -> Int {
        switch scope {
        case .user: 2
        case .system: 1
        case .unspecified: 0
        }
    }
}

// MARK: - Merged feature status

/// One status per feature across a VM's peers.
public enum FeatureStatus {
    /// Each feature available from the first peer offering it, in the tables'
    /// order; else the peers' absence that `absencePrecedence` ranks first,
    /// whatever the order (equal reasons: the least debug detail);
    /// `NO_AGENT` with no peer at all.
    public static func merge(_ tables: [FeatureStatusTable]) -> FeatureStatusTable {
        let features = FeatureDescriptor.all.map(\.feature)
        return FeatureStatusTable(
            features.map { feature in
                guard !tables.isEmpty else {
                    return (feature: feature, status: .absent(.noAgent, debugDetail: ""))
                }
                let statuses = tables.map { $0[feature] }
                if let available = statuses.first(where: \.isAvailable) {
                    return (feature: feature, status: available)
                }
                let absences = statuses.compactMap { status -> (rank: Int, reason: AbsenceReason, detail: String)? in
                    guard case .absent(let reason, let detail) = status else { return nil }
                    return (rank(reason), reason, detail)
                }
                let chosen = absences.min { ($0.rank, $0.detail) < ($1.rank, $1.detail) }
                return (
                    feature: feature, status: chosen.map { .absent($0.reason, debugDetail: $0.detail) } ?? statuses[0]
                )
            })
    }

    /// The order an absence wins the merge in: what an update fixes, then what
    /// the user can change, the nearest fix first; reasons that name no fix last.
    public static let absencePrecedence: [AbsenceReason] = [
        .protocolMismatch, .versionMismatch, .disabledByPolicy, .turnedOffInGuest, .notPermitted, .notOnConsole,
        .unsavedWorkUnseen, .noUserSession, .missingOsComponent, .notServedByRole, .notImplemented, .unspecified,
        .noAgent,
    ]

    static func rank(_ reason: AbsenceReason) -> Int {
        absencePrecedence.firstIndex(of: reason) ?? absencePrecedence.count
    }
}

// MARK: - Power routing

/// The hub's view of one connected peer, for routing.
public struct RoutingPeer: Sendable, Equatable {
    /// The hub's handle.
    public var handle: PeerHandle
    /// Its role.
    public var role: PeerRole
    /// Its latest state.
    public var state: PeerSessionState
    /// Its connection order; higher is newer.
    public var connectedOrder: UInt64
    /// Whether POWER is usable on its connection.
    public var powerUsable: Bool
    /// The actions its `PowerCapability` lists.
    public var actions: [PowerAction]
    /// The actions its `PowerCapability` lists as performed without waiting for the apps that block them.
    public var skippingBlockers: [PowerAction]

    /// The view of a peer from its latest `featuresChanged` table: POWER usable
    /// when the table says so, the actions its `PowerCapability` lists.
    public init(
        handle: PeerHandle, role: PeerRole, state: PeerSessionState, connectedOrder: UInt64,
        features: FeatureStatusTable
    ) {
        let power = features[.power]
        let offer = power.params.flatMap(PowerOffer.init(params:))
        self.init(
            handle: handle, role: role, state: state, connectedOrder: connectedOrder, powerUsable: power.isAvailable,
            actions: offer?.actions ?? [], skippingBlockers: offer?.skippingBlockers ?? [])
    }

    /// Creates a view.
    public init(
        handle: PeerHandle, role: PeerRole, state: PeerSessionState, connectedOrder: UInt64, powerUsable: Bool,
        actions: [PowerAction], skippingBlockers: [PowerAction] = []
    ) {
        self.handle = handle
        self.role = role
        self.state = state
        self.connectedOrder = connectedOrder
        self.powerUsable = powerUsable
        self.actions = actions
        self.skippingBlockers = skippingBlockers
    }
}

/// What routing asks the hub to do, or reports.
public enum RoutingOutput: Sendable, Equatable {
    /// Send `action` to this peer as a power request, skipping the apps that block it when
    /// `skippingBlockers`.
    case ask(PeerHandle, PowerAction, skippingBlockers: Bool = false)
    /// Progress after acceptance.
    case progress(PeerHandle, PowerStage, [AppValue])
    /// The guest is going down.
    case handedOff(PeerHandle)
    /// Apps blocked it. `skippable` when a peer offers the action without waiting for them.
    case blocked(PeerHandle, [AppValue], skippable: Bool)
    /// A user in the guest cancelled it.
    case cancelledInGuest(PeerHandle)
    /// The OS failed after accepting.
    case failed(PeerHandle, WireError)
    /// The host cannot know what happened; offer Force Stop.
    case indeterminate(PeerHandle)
    /// The connection ended after acceptance.
    case lostAfterAcceptance(PeerHandle)
    /// No peer candidate took it, `refusals` saying why each one asked declined: nothing was done. For a
    /// routing that waits for blocking apps the ACPI button stands in; for one skipping them, nothing does.
    case unserved(refusals: [PeerRefusal])
    /// A routing is already running for this VM.
    case busy
}

/// One peer's refusal during routing.
public struct PeerRefusal: Sendable, Equatable {
    /// The peer.
    public var peer: PeerHandle
    /// Why.
    public var error: WireError

    /// Creates a refusal.
    public init(peer: PeerHandle, error: WireError) {
        self.peer = peer
        self.error = error
    }
}

/// Routes one power action per VM across its peers.
public struct PowerRouting: Sendable {
    private struct Active: Sendable {
        var action: PowerAction
        var skippingBlockers: Bool
        var asked: [PeerHandle] = []
        var refusals: [PeerRefusal] = []
        var current: PeerHandle?
        var accepted = false
    }

    private var active: Active?
    private var outputs: [RoutingOutput] = []

    /// No routing running.
    public init() {}

    /// Whether a routing is running.
    public var isRouting: Bool { active != nil }

    /// Starts routing `action`, or reports `.busy`. A routing `skippingBlockers` asks only the peers
    /// offering `action` that way.
    public mutating func begin(_ action: PowerAction, skippingBlockers: Bool = false, peers: [RoutingPeer]) {
        guard active == nil else { return outputs.append(.busy) }
        active = Active(action: action, skippingBlockers: skippingBlockers)
        askNext(peers)
    }

    /// The asked peer's result.
    public mutating func handle(_ result: PowerRequestResult, from peer: PeerHandle, peers: [RoutingPeer]) {
        guard var routing = active, routing.current == peer else { return }
        switch result {
        case .accepted:
            routing.accepted = true
            active = routing
        case .progress(let stage, let apps):
            if routing.accepted { outputs.append(.progress(peer, stage, apps)) }
        case .refused(let error):
            guard !routing.accepted else { return end(.indeterminate(peer)) }
            routing.refusals.append(PeerRefusal(peer: peer, error: error))
            routing.current = nil
            active = routing
            askNext(peers)
        case .indeterminate:
            end(.indeterminate(peer))
        case .lostAfterAcceptance:
            end(.lostAfterAcceptance(peer))
        case .finished(let finish):
            switch finish {
            case .handedOff: end(.handedOff(peer))
            case .blocked(let apps):
                let skippable =
                    !routing.skippingBlockers
                    && !Self.candidates(for: routing.action, skippingBlockers: true, peers: peers, excluding: [])
                        .isEmpty
                end(.blocked(peer, apps, skippable: skippable))
            case .cancelledInGuest: end(.cancelledInGuest(peer))
            case .failed(let error): end(.failed(peer, error))
            }
        }
    }

    /// The next output for the hub.
    public mutating func pollOutput() -> RoutingOutput? {
        outputs.isEmpty ? nil : outputs.removeFirst()
    }

    /// The candidates for `action` in order, excluding `asked`: those offering it `skippingBlockers` or not.
    public static func candidates(
        for action: PowerAction, skippingBlockers: Bool = false, peers: [RoutingPeer], excluding asked: [PeerHandle]
    ) -> [PeerHandle] {
        let eligible = peers.filter { peer in
            peer.powerUsable && (skippingBlockers ? peer.skippingBlockers : peer.actions).contains(action)
                && !asked.contains(peer.handle)
        }
        let sessions = peers.filter { $0.role == .sessionPeer }
        let consoleOwners: [RoutingPeer]
        switch peers.first(where: { $0.role == .systemPeer })?.state {
        case let system? where system.console == .on:
            consoleOwners = sessions.filter { $0.state.sessionID == system.consoleSessionID }
        case let system? where system.console == .off:
            consoleOwners = []
        default:
            // No system peer, or one that does not know: no console authority, so
            // each session peer's own report decides.
            consoleOwners = sessions.filter { $0.state.console == .on }
        }
        let consoleHandles = consoleOwners.sorted { $0.connectedOrder > $1.connectedOrder }.map(\.handle)
        let systemHandles = peers.filter { $0.role == .systemPeer }.map(\.handle)
        return (consoleHandles + systemHandles).filter { handle in eligible.contains { $0.handle == handle } }
    }

    private mutating func askNext(_ peers: [RoutingPeer]) {
        guard var routing = active else { return }
        guard
            let next = Self.candidates(
                for: routing.action, skippingBlockers: routing.skippingBlockers, peers: peers,
                excluding: routing.asked
            ).first
        else {
            return end(.unserved(refusals: routing.refusals))
        }
        routing.asked.append(next)
        routing.current = next
        active = routing
        outputs.append(.ask(next, routing.action, skippingBlockers: routing.skippingBlockers))
    }

    private mutating func end(_ output: RoutingOutput) {
        active = nil
        outputs.append(output)
    }
}
