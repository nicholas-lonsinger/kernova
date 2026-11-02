#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One connection that has said Hello.
struct PeerRecord: Sendable {
    var handle: PeerHandle
    /// The connection that said the Hello.
    var connection: any HostConnectionHandle
    var claim: PeerClaim
    var state: PeerSessionState
    /// Its latest `featuresChanged`; `nil` until the first, which the host endpoint emits with the Hello
    /// it answers, so a peer is shown only once its features are known.
    var features: FeatureStatusTable?
    var isResponsive = true
    /// Higher is newer.
    var connectedOrder: UInt64
    /// The pull open on the connection, and the hash it pulls.
    var pull: (id: UpdatePullID, hash: Data)?
    /// The payload hash whose pull on this connection ended without installing it. The peer pulls no hash
    /// twice on one connection, so it will not update itself to this one before it reconnects.
    var failedPullHash: Data?
    /// The peer installed an update on this connection, so its close is the relaunch into it.
    var stagedUpdate = false

    /// Who the peer is across its connections: a reboot or a relaunch gives a session peer a new session, so
    /// its user, not its session, names it.
    var awayKey: AwayKey {
        AwayKey(isSystemPeer: claim.role == .systemPeer, userName: claim.role == .systemPeer ? "" : state.userName)
    }

    var conflictParty: ConflictParty {
        ConflictParty(claim: claim, state: state, isUnresponsive: !isResponsive)
    }
}

/// A peer's identity across its connections, for the away memory.
struct AwayKey: Hashable, Sendable {
    var isSystemPeer: Bool
    var userName: String
}

/// What a newly read Hello does to the peer set.
enum HelloOutcome: Sendable, Equatable {
    /// It joined the peer set.
    case joined
    /// It joined; `existing` lost to it and closes as `close` says.
    case displaced(existing: PeerHandle, ErrorCode, retryAfter: CoreDuration?)
    /// It lost to a peer already present and closes as `close` says.
    case refused(ErrorCode, retryAfter: CoreDuration?)
}

/// The hub's whole state, touched only on the hub's queue.
struct AgentHubState: Sendable {
    /// Every live connection, said Hello or not: what the hub's commands reach.
    var connections: [PeerHandle: any HostConnectionHandle] = [:]
    /// The connections that said Hello and won any conflict.
    var peers: [PeerHandle: PeerRecord] = [:]
    /// The attached transport, and the acceptor admitting its connections.
    var attachment: (transport: any GuestStreamTransport, acceptor: GuestStreamAcceptor)?
    /// Counts attaches: which transport accepted a connection, so one an earlier attachment accepted, ending
    /// after a later one began, is never remembered as away from the later one.
    var attachmentGeneration: UInt64 = 0
    /// The attachment that accepted each live connection.
    var connectionAttachments: [PeerHandle: UInt64] = [:]
    var republisher: GuestLogRepublisher?
    var bundles: [BundledPayload] = []
    var isFrozen = false
    var isClosed = false
    var power = HubPowerRouting()
    var lastPublished = AgentHubSnapshot.empty
    private var nextConnectedOrder: UInt64 = 0
    /// The peers seen on this attachment that are disconnected now, by who they are.
    var away: [AwayKey: AwayPeer] = [:]
    private var nextAwayOrder: UInt64 = 0

    /// Adds the peer whose Hello `handle`'s connection read, resolving it against the one peer that can
    /// already hold its identity (spec §4.5): every Hello is resolved as it arrives, so no two peers in
    /// the set share a key.
    mutating func helloReceived(_ handle: PeerHandle, claim: PeerClaim, state: PeerSessionState) -> HelloOutcome? {
        guard let connection = connections[handle] else { return nil }
        nextConnectedOrder += 1
        let incoming = PeerRecord(
            handle: handle, connection: connection, claim: claim, state: state, connectedOrder: nextConnectedOrder)
        for (existingHandle, existing) in peers {
            switch PeerConflict.resolve(existing: existing.conflictParty, incoming: incoming.conflictParty) {
            case .noConflict:
                continue
            case .closeExisting(let code, let retryAfter):
                peers[existingHandle] = nil
                peers[handle] = incoming
                return .displaced(existing: existingHandle, code, retryAfter: retryAfter)
            case .closeIncoming(let code, let retryAfter):
                return .refused(code, retryAfter: retryAfter)
            }
        }
        peers[handle] = incoming
        return .joined
    }

    /// A peer joined the set: it is no longer away.
    mutating func joined(_ handle: PeerHandle) {
        guard let record = peers[handle] else { return }
        away[record.awayKey] = nil
    }

    /// The connection ended: it leaves the hub. A peer the snapshot showed is remembered as away while the
    /// transport that accepted it is attached, with the standing it left with.
    mutating func closed(_ handle: PeerHandle) {
        connections[handle] = nil
        let accepted = connectionAttachments.removeValue(forKey: handle)
        guard let record = peers.removeValue(forKey: handle) else { return }
        guard attachment != nil, accepted == attachmentGeneration, record.features != nil else { return }
        nextAwayOrder += 1
        away[record.awayKey] = AwayPeer(
            summary: summary(record), relaunching: record.stagedUpdate, order: nextAwayOrder)
    }

    /// Forgets the away peers that went away at or before `order`.
    mutating func forgetAway(through order: UInt64) {
        away = away.filter { $0.value.order > order }
    }

    /// Forgets everything an attachment saw: the next one serves a new session of the guest.
    mutating func resetAttachmentMemory() {
        away = [:]
    }

    /// The routing view of every peer whose features are known. An unresponsive peer's POWER is not
    /// usable: a request to it could only end in the host's wait expiring, which stops the routing as
    /// indeterminate where the next candidate could have served.
    var routingPeers: [RoutingPeer] {
        peers.values.compactMap { record in
            guard let features = record.features else { return nil }
            var peer = RoutingPeer(
                handle: record.handle, role: record.claim.role, state: record.state,
                connectedOrder: record.connectedOrder, features: features)
            peer.powerUsable = peer.powerUsable && record.isResponsive
            return peer
        }
    }

    var snapshot: AgentHubSnapshot {
        let ordered = peers.values.filter { $0.features != nil }.sorted { $0.connectedOrder > $1.connectedOrder }
        let features = FeatureStatus.merge(ordered.compactMap(\.features))
        return AgentHubSnapshot(
            peers: ordered.map(summary), features: features, power: provision(features: features),
            routing: power.progress, away: away.values.sorted { $0.order > $1.order })
    }

    /// The merged POWER entry: the first candidate a shutdown would ask, else the merged absence — with
    /// `NOT_ON_CONSOLE` for a peer that offers POWER but serves no console session.
    private func provision(features: FeatureStatusTable) -> PowerProvision {
        let candidates = routingPeers
        if let first = PowerRouting.candidates(for: .shutdown, peers: candidates, excluding: []).first,
            let role = peers[first]?.claim.role
        {
            return .agent(role)
        }
        switch features[.power] {
        case .absent(let reason, _): return .absent(reason)
        case .available: return .absent(.notOnConsole)
        }
    }

    private func summary(_ record: PeerRecord) -> PeerSummary {
        let standing: PeerSummary.Standing =
            switch BundledPayload.offer(from: bundles, for: record.claim) {
            case nil: .notOffered
            case let offered? where offered.payloadHash == record.claim.payloadHash: .current
            case let offered?:
                .outdated(offeredVersionLabel: offered.versionLabel, update: Self.inBandUpdate(record, to: offered))
            }
        return PeerSummary(
            handle: record.handle, role: record.claim.role, scope: record.claim.scope,
            os: record.claim.os, sessionID: record.state.sessionID, userName: record.state.userName,
            console: record.state.console, versionLabel: record.claim.versionLabel,
            standing: standing, isResponsive: record.isResponsive)
    }

    /// Whether `record`'s peer is updating itself to `offered`.
    private static func inBandUpdate(_ record: PeerRecord, to offered: UpdateManifestValue) -> PeerSummary.InBandUpdate
    {
        guard case .available(let params)? = record.features?[.update], let offer = UpdateOffer(params: params),
            offer.formats.contains(offered.format)
        else { return .unavailable }
        if offer.rejectedHash == offered.payloadHash || record.failedPullHash == offered.payloadHash { return .failed }
        return .updating
    }

    /// `handle`'s connection reported `event` of a pull: what the peer's standing reads of it.
    mutating func updateServed(_ event: UpdateServeEvent, from handle: PeerHandle) {
        guard var record = peers[handle] else { return }
        switch event {
        case .pullRequested(let id, let manifest):
            record.pull = (id, manifest.payloadHash)
        case .result(let id, let result):
            guard let pull = record.pull, pull.id == id else { return }
            record.pull = nil
            if result.kind == .rejected { record.failedPullHash = pull.hash } else { record.stagedUpdate = true }
        case .closed(let id, _):
            guard let pull = record.pull, pull.id == id else { return }
            record.pull = nil
            record.failedPullHash = pull.hash
        }
        peers[handle] = record
    }
}
