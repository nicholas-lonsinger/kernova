import Foundation
import KernovaCommandModel

extension VMLifecyclePhase {
    /// The coarse state this phase is in: running while a session is live,
    /// otherwise wherever the VM rests.
    ///
    /// Liveness rather than ``status``: a status names an operation, and a
    /// cold snapshot capture or a revert that does not resume shows its own
    /// while no session is live.
    var stateBucket: VMStateBucket {
        if sessionID != nil { return .running }
        switch self {
        case .suspended: return .suspended
        case .stopped, .initialBoot, .failed, .removed: return .stopped
        case .running, .livePaused: return .running
        case .operating(let operation):
            // A suspend slot outliving an ended session is a bundle fact no
            // phase holds — as for `presented`, the ending commit settles it.
            return operation.settledBasis(slotOnDisk: false).stateBucket
        }
    }
}

extension VMInstance {
    /// The coarse state this VM is in, as this copy sees it.
    var stateBucket: VMStateBucket {
        heldByAnotherCopy ? .heldByAnotherCopy : phase.stateBucket
    }

    /// What a ``VMLibraryFilter`` reads of this VM, with `networks` the
    /// library's named networks and `tags` its tags.
    func filterSubject(
        bundledAgents: BundledGuestAgents, networks: VMNetworkDirectory.State, tags: [VMTag]
    ) -> VMLibraryFilter.Subject {
        VMLibraryFilter.Subject(
            configuration, lastSeenAgentVersions: [lastSeenAgentVersion, lastSeenSystemAgentVersion],
            state: stateBucket, hostState: hostState, hasSnapshots: !snapshotManifest.isEmpty, tags: tags,
            bundledAgents: bundledAgents, networks: networks)
    }
}

extension VMArrival {
    /// What a ``VMLibraryFilter`` reads of this arrival: preparing, with no
    /// session, and with the Ephemeral Mode, snapshots and tags of the VM it
    /// becomes as far as ``starting`` knows them; `networks` is the library's
    /// named networks and `tags` its tags.
    func filterSubject(
        bundledAgents: BundledGuestAgents, networks: VMNetworkDirectory.State, tags: [VMTag]
    ) -> VMLibraryFilter.Subject {
        VMLibraryFilter.Subject(
            configuration,
            lastSeenAgentVersions: [configuration.lastSeenAgentVersion, configuration.lastSeenSystemAgentVersion],
            state: .preparing, hostState: starting.hostState, hasSnapshots: starting.hasSnapshots, tags: tags,
            bundledAgents: bundledAgents, networks: networks)
    }
}

extension LibraryEntry {
    /// What a ``VMLibraryFilter`` reads of this entry, with `networks` the
    /// library's named networks and `tags` its tags; `nil` for a bundle
    /// Kernova can't read, which holds nothing a filter reads.
    func filterSubject(
        bundledAgents: BundledGuestAgents, networks: VMNetworkDirectory.State, tags: [VMTag]
    ) -> VMLibraryFilter.Subject? {
        switch self {
        case .vm(let instance):
            instance.filterSubject(bundledAgents: bundledAgents, networks: networks, tags: tags)
        case .arriving(let arrival):
            arrival.filterSubject(bundledAgents: bundledAgents, networks: networks, tags: tags)
        case .unreadable: nil
        }
    }
}

extension VMLibraryFilter.Subject {
    /// The subject of a VM configured as `configuration` whose host state is
    /// `hostState`, carrying the tags of `tags` — the library's — it assigns,
    /// and whose agents last reported `lastSeenAgentVersions`, one per scope.
    fileprivate init(
        _ configuration: VMConfiguration, lastSeenAgentVersions: [String?], state: VMStateBucket,
        hostState: VMHostState, hasSnapshots: Bool, tags: [VMTag], bundledAgents: BundledGuestAgents,
        networks: VMNetworkDirectory.State
    ) {
        self.init(
            guestOS: configuration.guestOS, state: state,
            network: VMLibraryFilter.Network(NetworkModeChoice(configuration)) { kind, id in
                // While the list can't be read, no named network is known to
                // be one the library does not list.
                networks.listed?.contains { $0.id == id && $0.kind == kind } ?? true
            },
            guestAgent: VMGuestAgentBucket(
                lastSeen: lastSeenAgentVersions.compactMap { $0 },
                bundled: bundledAgents.versionLabel(for: configuration.guestOS)),
            isEphemeral: hostState.ephemeralModeEnabled, hasSnapshots: hasSnapshots,
            tags: Set(tags.assigned(hostState.tags).map(\.id)))
    }
}

extension VMGuestAgentBucket {
    /// The bucket of a VM whose agents last reported the version labels
    /// `lastSeen`, one per scope that ever connected, against the label of the
    /// payloads bundled for its guest OS: up to date only when each is that
    /// label — the agent hub offers any other agent the bundled payload — and
    /// `nil` when an agent has connected and nothing is bundled to judge it
    /// against.
    init?(lastSeen: [String], bundled: String?) {
        guard !lastSeen.isEmpty else {
            self = .neverConnected
            return
        }
        guard let bundled else { return nil }
        self = lastSeen.allSatisfy { $0 == bundled } ? .upToDate : .olderVersion
    }
}
