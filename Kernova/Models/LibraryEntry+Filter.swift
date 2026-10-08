import Foundation
import KernovaKit

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
        bundledAgentVersion: String?, networks: VMNetworkDirectory.State, tags: [VMTag]
    ) -> VMLibraryFilter.Subject {
        VMLibraryFilter.Subject(
            configuration, lastSeenAgentVersion: lastSeenAgentVersion, state: stateBucket,
            isEphemeral: hostState.ephemeralModeEnabled, hasSnapshots: !snapshotManifest.isEmpty,
            tags: Set(tags.assigned(hostState.tags).map(\.id)),
            bundledAgentVersion: bundledAgentVersion, networks: networks)
    }
}

extension VMArrival {
    /// What a ``VMLibraryFilter`` reads of this arrival: preparing, with no
    /// session, and with the Ephemeral Mode, snapshots and tags of the VM it
    /// becomes as far as ``starting`` knows them; `networks` is the library's
    /// named networks and `tags` its tags.
    func filterSubject(
        bundledAgentVersion: String?, networks: VMNetworkDirectory.State, tags: [VMTag]
    ) -> VMLibraryFilter.Subject {
        VMLibraryFilter.Subject(
            configuration, lastSeenAgentVersion: configuration.lastSeenAgentVersion, state: .preparing,
            isEphemeral: starting.hostState.ephemeralModeEnabled, hasSnapshots: starting.hasSnapshots,
            tags: Set(tags.assigned(starting.hostState.tags).map(\.id)), bundledAgentVersion: bundledAgentVersion,
            networks: networks)
    }
}

extension LibraryEntry {
    /// What a ``VMLibraryFilter`` reads of this entry, with `networks` the
    /// library's named networks and `tags` its tags; `nil` for a bundle
    /// Kernova can't read, which holds nothing a filter reads.
    func filterSubject(
        bundledAgentVersion: String?, networks: VMNetworkDirectory.State, tags: [VMTag]
    ) -> VMLibraryFilter.Subject? {
        switch self {
        case .vm(let instance):
            instance.filterSubject(bundledAgentVersion: bundledAgentVersion, networks: networks, tags: tags)
        case .arriving(let arrival):
            arrival.filterSubject(bundledAgentVersion: bundledAgentVersion, networks: networks, tags: tags)
        case .unreadable: nil
        }
    }
}

extension VMLibraryFilter.Subject {
    fileprivate init(
        _ configuration: VMConfiguration, lastSeenAgentVersion: String?, state: VMStateBucket,
        isEphemeral: Bool, hasSnapshots: Bool, tags: Set<UUID>, bundledAgentVersion: String?,
        networks: VMNetworkDirectory.State
    ) {
        self.init(
            guestOS: configuration.guestOS, state: state,
            network: VMLibraryFilter.Network(NetworkModeChoice(configuration)) { kind, id in
                // While the list can't be read, no named network is known to
                // be one the library does not list.
                networks.listed?.contains { $0.id == id && $0.kind == kind } ?? true
            },
            guestAgent: configuration.guestOS == .macOS
                ? VMGuestAgentBucket(lastSeenVersion: lastSeenAgentVersion, bundledVersion: bundledAgentVersion)
                : nil,
            isEphemeral: isEphemeral, hasSnapshots: hasSnapshots, tags: tags)
    }
}
