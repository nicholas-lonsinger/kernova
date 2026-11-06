#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentRuntime
import KernovaWire

/// One connection that has said Hello.
struct PeerRecord: ConsolePeer, Sendable {
    var handle: PeerHandle
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
    /// The payload whose pull on this connection ended without installing it, with the code the peer's
    /// refusal reported, if it reported one. The peer pulls no hash twice on one connection, so it will not
    /// update itself to this one before it reconnects.
    var failedPull: RejectedPayload?
    /// The peer installed an update on this connection, so its close is the relaunch into it.
    var stagedUpdate = false

    /// Who the peer is across its connections: a reboot or a relaunch gives a session peer a new session, so
    /// its user, not its session, names it.
    var awayKey: AwayKey {
        AwayKey(isSystemPeer: claim.role == .systemPeer, userName: claim.role == .systemPeer ? "" : state.userName)
    }

    var role: PeerRole { claim.role }

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

/// One live connection, said Hello or not.
struct ConnectionEntry: Sendable {
    /// What the hub's commands reach.
    var connection: any HostConnectionHandle
    /// The attachment that accepted it.
    var attachment: UInt64
    /// Its peer, once its Hello joined the peer set; nil before, after a refused Hello, and once another
    /// connection displaced it.
    var peer: PeerRecord?
    /// What the owner of the hub's item events holds open on it.
    var items = HubOpenItems()
}

/// The hub's whole state, touched only on the hub's queue.
struct AgentHubState: Sendable {
    /// Every live connection, by its handle.
    var connections: [PeerHandle: ConnectionEntry] = [:]
    /// The attached transport, and the acceptor admitting its connections.
    var attachment: (transport: any GuestStreamTransport, acceptor: GuestStreamAcceptor)?
    /// Counts attaches: which transport accepted a connection, so one an earlier attachment accepted, ending
    /// after a later one began, is never remembered as away from the later one.
    var attachmentGeneration: UInt64 = 0
    var republisher: GuestLogRepublisher?
    var bundles: [BundledPayload] = []
    var isFrozen = false
    var isClosed = false
    var power = HubPowerRouting()
    var items = ItemRequests<PeerHandle>()
    /// The console peer of each feature that offers items, as the owner last heard it.
    var itemConsole: [FeatureID: PeerHandle] = [:]
    var lastPublished = AgentHubSnapshot.empty
    private var nextConnectedOrder: UInt64 = 0
    /// The last close of each identity seen on this attachment. The snapshot shows an entry only while no
    /// visible peer has its identity, so a returning peer reads as away until its features arrive.
    var away: [AwayKey: AwayPeer] = [:]
    private var nextAwayOrder: UInt64 = 0

    /// Adds the peer whose Hello `handle`'s connection read, resolving it against the one peer that can
    /// already hold its identity (spec §4.5): every Hello is resolved as it arrives, so no two peers in
    /// the set share a key.
    mutating func helloReceived(_ handle: PeerHandle, claim: PeerClaim, state: PeerSessionState) -> HelloOutcome? {
        guard connections[handle] != nil else { return nil }
        nextConnectedOrder += 1
        let incoming = PeerRecord(handle: handle, claim: claim, state: state, connectedOrder: nextConnectedOrder)
        for existing in peers {
            switch PeerConflict.resolve(existing: existing.conflictParty, incoming: incoming.conflictParty) {
            case .noConflict:
                continue
            case .closeExisting(let code, let retryAfter):
                connections[existing.handle]?.peer = nil
                connections[handle]?.peer = incoming
                return .displaced(existing: existing.handle, code, retryAfter: retryAfter)
            case .closeIncoming(let code, let retryAfter):
                return .refused(code, retryAfter: retryAfter)
            }
        }
        connections[handle]?.peer = incoming
        return .joined
    }

    /// The connection ended `at` that instant: it leaves the hub. A peer the snapshot showed is remembered as
    /// away while the transport that accepted it is attached, with the standing it left with.
    mutating func closed(_ handle: PeerHandle, at instant: CoreInstant) {
        guard let entry = connections.removeValue(forKey: handle), let record = entry.peer else { return }
        guard attachment != nil, entry.attachment == attachmentGeneration, record.features != nil else { return }
        nextAwayOrder += 1
        away[record.awayKey] = AwayPeer(
            summary: summary(record), relaunching: record.stagedUpdate, order: nextAwayOrder, since: instant)
    }

    /// The connections that said Hello and won any conflict.
    var peers: [PeerRecord] {
        connections.values.compactMap(\.peer)
    }

    /// Forgets everything an attachment saw: the next one serves a new session of the guest.
    mutating func resetAttachmentMemory() {
        away = [:]
    }

    /// The peers whose features are known: the ones the snapshot shows, and the only ones power and items
    /// are routed to.
    private var visiblePeers: [PeerRecord] {
        peers.filter { $0.features != nil }
    }

    /// The routing view of every visible peer. An unresponsive peer's POWER is not usable: a request to it
    /// could only end in the host's wait expiring, which stops the routing as indeterminate where the next
    /// candidate could have served.
    var routingPeers: [RoutingPeer] {
        visiblePeers.compactMap { record in
            guard let features = record.features else { return nil }
            var peer = RoutingPeer(
                handle: record.handle, role: record.claim.role, state: record.state,
                connectedOrder: record.connectedOrder, features: features)
            peer.powerUsable = peer.powerUsable && record.isResponsive
            return peer
        }
    }

    /// `feature`'s console peer: the newest peer of the console's session whose connection offers it.
    func consolePeer(for feature: FeatureID) -> PeerHandle? {
        ConsoleAuthority.consolePeers(visiblePeers).first { $0.features?[feature].isAvailable == true }?.handle
    }

    /// Why no peer is `feature`'s console peer.
    func consoleAbsence(of feature: FeatureID) -> AbsenceReason {
        Self.absence(of: feature, in: FeatureStatus.merge(visiblePeers.compactMap(\.features)))
    }

    var snapshot: AgentHubSnapshot {
        let ordered = visiblePeers.sorted { $0.connectedOrder > $1.connectedOrder }
        let visible = Set(ordered.map(\.awayKey))
        let features = FeatureStatus.merge(ordered.compactMap(\.features))
        var consolePeers: [FeatureID: PeerHandle] = [:]
        for feature in ItemFeatureAvailability.offering {
            consolePeers[feature] = consolePeer(for: feature)
        }
        return AgentHubSnapshot(
            peers: ordered.map(summary), features: features,
            away: away.filter { !visible.contains($0.key) }.values.sorted { $0.order > $1.order },
            power: provision(ignoringApps: false, features: features),
            powerIgnoringApps: provision(ignoringApps: true, features: features),
            routing: power.progress, consolePeers: consolePeers)
    }

    /// The merged POWER entry for a shutdown, without waiting for apps when `ignoringApps`: the first candidate
    /// it would ask, else why there is none — POWER's merged absence; then, with POWER offered, `NOT_ON_CONSOLE`
    /// for the graceful one, and for the one ignoring apps `NO_AGENT` when no peer offers it at all.
    private func provision(ignoringApps: Bool, features: FeatureStatusTable) -> PowerProvision {
        let peers = routingPeers
        if let first = PowerRouting.candidates(for: .shutdown, ignoringApps: ignoringApps, peers: peers, excluding: [])
            .first, let role = connections[first]?.peer?.claim.role
        {
            return .agent(role)
        }
        let absence = Self.absence(of: .power, in: features)
        guard ignoringApps, absence == .notOnConsole else { return .absent(absence) }
        return .absent(peers.contains { $0.offers(.shutdown, ignoringApps: true) } ? .unspecified : .noAgent)
    }

    /// Why no console peer serves `feature`: the merged absence, or `NOT_ON_CONSOLE` for a feature some peer
    /// offers while serving no console session.
    private static func absence(of feature: FeatureID, in features: FeatureStatusTable) -> AbsenceReason {
        switch features[feature] {
        case .absent(let reason, _): reason
        case .available: .notOnConsole
        }
    }

    private func summary(_ record: PeerRecord) -> PeerSummary {
        let standing: PeerSummary.Standing =
            if let bundle = BundledPayload.bundle(from: bundles, for: record.claim) {
                if bundle.manifest.payloadHash == record.claim.payloadHash {
                    .current
                } else {
                    .outdated(
                        offeredVersionLabel: bundle.manifest.versionLabel,
                        update: bundle.offered.map { Self.inBandUpdate(record, to: $0) } ?? .notTeamSigned)
                }
            } else {
                .notOffered
            }
        return PeerSummary(
            handle: record.handle, role: record.claim.role, scope: record.claim.scope,
            os: record.claim.os, sessionID: record.state.sessionID, userName: record.state.userName,
            console: record.state.console, versionLabel: record.claim.versionLabel,
            standing: standing, isResponsive: record.isResponsive, osVersion: record.claim.osVersion,
            payloadHash: record.claim.payloadHash)
    }

    /// Whether `record`'s peer is updating itself to `offered`.
    private static func inBandUpdate(_ record: PeerRecord, to offered: UpdateManifestValue) -> PeerSummary.InBandUpdate
    {
        guard case .available(let params)? = record.features?[.update], let offer = UpdateOffer(params: params),
            offer.formats.contains(offered.format)
        else { return .unavailable }
        let refusals = [offer.rejected, record.failedPull].compactMap { $0 }.filter {
            $0.hash == offered.payloadHash
        }
        if refusals.contains(where: { $0.code == .updateLaunchRefused }) { return .launchRefused }
        return refusals.isEmpty ? .updating : .failed
    }

    /// `handle`'s connection reported `event` of a pull: what the peer's standing reads of it.
    mutating func updateServed(_ event: UpdateServeEvent, from handle: PeerHandle) {
        guard var record = connections[handle]?.peer else { return }
        switch event {
        case .pullRequested(let id, let manifest):
            record.pull = (id, manifest.payloadHash)
        case .result(let id, let result):
            guard let pull = record.pull, pull.id == id else { return }
            record.pull = nil
            if result.kind == .rejected {
                record.failedPull = RejectedPayload(hash: pull.hash, code: result.error?.code)
            } else {
                record.stagedUpdate = true
            }
        case .closed(let id, _):
            guard let pull = record.pull, pull.id == id else { return }
            record.pull = nil
            record.failedPull = RejectedPayload(hash: pull.hash)
        }
        connections[handle]?.peer = record
    }
}
