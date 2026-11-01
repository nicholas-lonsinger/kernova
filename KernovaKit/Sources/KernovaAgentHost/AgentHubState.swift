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

    var conflictParty: ConflictParty {
        ConflictParty(claim: claim, state: state, isUnresponsive: !isResponsive)
    }
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
    var republisher: GuestLogRepublisher?
    var bundles: [BundledPayload] = []
    var isFrozen = false
    var isClosed = false
    var power = HubPowerRouting()
    var lastPublished = AgentHubSnapshot.empty
    private var nextConnectedOrder: UInt64 = 0

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

    /// The connection ended: it leaves the hub.
    mutating func closed(_ handle: PeerHandle) {
        connections[handle] = nil
        peers[handle] = nil
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
            peers: ordered.map(summary), features: features, power: provision(ordered), routing: power.progress)
    }

    /// The merged POWER entry for a shutdown that waits for blocking apps: the first candidate it would
    /// ask, else the merged absence of `ordered`'s offers of it — with `NOT_ON_CONSOLE` for a peer that
    /// offers it but serves no console session.
    private func provision(_ ordered: [PeerRecord]) -> PowerProvision {
        let candidates = routingPeers
        if let first = PowerRouting.candidates(for: .shutdown, peers: candidates, excluding: []).first,
            let role = peers[first]?.claim.role
        {
            return .agent(role)
        }
        let waiting = ordered.compactMap(\.features).map { table in
            FeatureStatusTable([(.power, PowerOffer.waitingStatus(table[.power]))])
        }
        switch FeatureStatus.merge(waiting)[.power] {
        case .absent(let reason, _): return .absent(reason)
        case .available: return .absent(.notOnConsole)
        }
    }

    private func summary(_ record: PeerRecord) -> PeerSummary {
        let standing: PeerSummary.Standing =
            switch BundledPayload.offer(from: bundles, for: record.claim) {
            case nil: .notOffered
            case let offered? where offered.payloadHash == record.claim.payloadHash: .current
            case let offered?: .outdated(offeredVersionLabel: offered.versionLabel)
            }
        return PeerSummary(
            handle: record.handle, role: record.claim.role, scope: record.claim.scope,
            os: record.claim.os, sessionID: record.state.sessionID, userName: record.state.userName,
            console: record.state.console, versionLabel: record.claim.versionLabel,
            standing: standing, isResponsive: record.isResponsive)
    }
}
