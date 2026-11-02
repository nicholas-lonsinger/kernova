#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One VM's agents as the main actor reads them: every peer, and one status per feature across them.
public struct AgentHubSnapshot: Sendable, Equatable {
    /// The peers, newest connection first.
    public var peers: [PeerSummary]
    /// `FeatureStatus.merge` of the peers' tables, newest first; every feature `NO_AGENT` with none.
    public var features: FeatureStatusTable
    /// Which agent a shutdown would ask first. POWER's own merged entry: `features[.power]` says only
    /// whether some peer offers it, and routing asks only the peers serving the console session.
    public var power: PowerProvision
    /// The power routing running now, if any.
    public var routing: PowerRoutingProgress?
    /// The peers seen while this transport is attached that are disconnected now, the most recently gone
    /// first; each leaves when a peer of its identity says Hello again, or ``AgentHub/forgetAway(through:)``
    /// drops it.
    public var away: [AwayPeer]

    /// A snapshot of these peers and merged features.
    public init(
        peers: [PeerSummary], features: FeatureStatusTable, power: PowerProvision = .absent(.noAgent),
        routing: PowerRoutingProgress? = nil, away: [AwayPeer] = []
    ) {
        self.peers = peers
        self.features = features
        self.power = power
        self.routing = routing
        self.away = away
    }

    /// No peer: every feature `NO_AGENT`.
    public static let empty = AgentHubSnapshot(peers: [], features: FeatureStatus.merge([]))
}

/// A peer that disconnected, as it was when it did.
public struct AwayPeer: Sendable, Equatable {
    /// The peer as the snapshot last showed it.
    public var summary: PeerSummary
    /// It closed after installing an update: it is relaunching into it, and returns once the new version
    /// connects or the rollback check restores the old one.
    public var relaunching: Bool
    /// Higher went away later; what ``AgentHub/forgetAway(through:)`` takes.
    public var order: UInt64

    /// Creates an away peer.
    public init(summary: PeerSummary, relaunching: Bool, order: UInt64) {
        self.summary = summary
        self.relaunching = relaunching
        self.order = order
    }
}

/// One connected peer, as the UI shows it.
public struct PeerSummary: Sendable, Equatable {
    /// The hub's handle on the connection.
    public var handle: PeerHandle
    /// Session or system peer.
    public var role: PeerRole
    /// Where it is installed.
    public var scope: InstallScope
    /// Its guest OS family.
    public var os: OSFamily
    /// Session peer: its session's identifier.
    public var sessionID: String
    /// Session peer: the session user's login name.
    public var userName: String
    /// Console ownership as the peer reports it.
    public var console: ConsoleState
    /// The version it reports.
    public var versionLabel: String
    /// How it stands against the payload the host offers it.
    public var standing: Standing
    /// Whether the host judges it responsive.
    public var isResponsive: Bool

    /// How a peer stands against the payload the host offers it.
    public enum Standing: Sendable, Equatable {
        /// The host offers it nothing, so says nothing of its version.
        case notOffered
        /// Its payload hash is the offered payload's.
        case current
        /// The host offers it the payload `offeredVersionLabel` names, which it does not run; `update` says
        /// whether it is updating itself to it.
        case outdated(offeredVersionLabel: String, update: InBandUpdate)
    }

    /// Whether an outdated peer is updating itself to the offered payload.
    public enum InBandUpdate: Sendable, Equatable {
        /// It offers UPDATE in the payload's format and has not refused it: it pulls the payload, or has
        /// installed it and is relaunching.
        case updating
        /// It refused the payload: its install records the payload's hash as rejected, as a rollback or a
        /// failed install does, or its pull of it on this connection ended without installing it, and the
        /// peer pulls no hash twice on one connection.
        case failed
        /// It cannot update itself to the payload: it offers no UPDATE, or none in the payload's format.
        case unavailable
    }

    /// Creates a summary.
    public init(
        handle: PeerHandle, role: PeerRole, scope: InstallScope, os: OSFamily, sessionID: String, userName: String,
        console: ConsoleState, versionLabel: String, standing: Standing, isResponsive: Bool
    ) {
        self.handle = handle
        self.role = role
        self.scope = scope
        self.os = os
        self.sessionID = sessionID
        self.userName = userName
        self.console = console
        self.versionLabel = versionLabel
        self.standing = standing
        self.isResponsive = isResponsive
    }
}
