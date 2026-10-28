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

    /// A snapshot of these peers and merged features.
    public init(peers: [PeerSummary], features: FeatureStatusTable) {
        self.peers = peers
        self.features = features
    }

    /// No peer: every feature `NO_AGENT`.
    public static let empty = AgentHubSnapshot(peers: [], features: FeatureStatus.merge([]))
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
        /// The host offers it the payload `offeredVersionLabel` names, which it does not run.
        case outdated(offeredVersionLabel: String)
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
