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
    /// Where the hub's commands for it go.
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
    var transport: (any GuestStreamTransport)?
    var republisher: GuestLogRepublisher?
    var bundles: [BundledPayload] = []
    var isFrozen = false
    var isClosed = false
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

    var snapshot: AgentHubSnapshot {
        let ordered = peers.values.filter { $0.features != nil }.sorted { $0.connectedOrder > $1.connectedOrder }
        return AgentHubSnapshot(
            peers: ordered.map(summary), features: FeatureStatus.merge(ordered.compactMap(\.features)))
    }

    private func summary(_ record: PeerRecord) -> PeerSummary {
        let offered = BundledPayload.offer(from: bundles, for: record.claim)
        return PeerSummary(
            handle: record.handle, role: record.claim.role, scope: record.claim.scope,
            os: record.claim.os, sessionID: record.state.sessionID, userName: record.state.userName,
            console: record.state.console, versionLabel: record.claim.versionLabel,
            isCurrent: offered.map { $0.payloadHash == record.claim.payloadHash } ?? true,
            offeredVersionLabel: offered?.versionLabel, isResponsive: record.isResponsive)
    }
}
