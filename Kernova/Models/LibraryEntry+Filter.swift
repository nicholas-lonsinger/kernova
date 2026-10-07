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
    /// Whether the bundle holds a snapshot other than the Ephemeral Mode
    /// baseline — what the Has Snapshots filter and query read.
    var hasSnapshotsBesideBaseline: Bool {
        snapshotManifest.snapshots.contains { !isEphemeralBaseline($0) }
    }

    /// The coarse state this VM is in, as this copy sees it.
    var stateBucket: VMStateBucket {
        heldByAnotherCopy ? .heldByAnotherCopy : phase.stateBucket
    }
}

extension LibraryEntry {
    /// What a ``VMLibraryFilter`` reads of this entry, with `networks` the
    /// library's named networks. An arrival is preparing, with no session, no
    /// Ephemeral Mode and no snapshots.
    func filterSubject(
        bundledAgentVersion: String?, networks: [VMNamedNetwork]
    ) -> VMLibraryFilter.Subject {
        let configuration = configuration
        let network = VMLibraryFilter.Network(NetworkModeChoice(configuration)) { kind, id in
            networks.contains { $0.id == id && $0.kind == kind }
        }
        let guestAgent =
            configuration.guestOS == .macOS
            ? VMGuestAgentBucket(
                lastSeenVersion: vm?.lastSeenAgentVersion ?? configuration.lastSeenAgentVersion,
                bundledVersion: bundledAgentVersion)
            : nil
        switch self {
        case .vm(let instance):
            return VMLibraryFilter.Subject(
                guestOS: configuration.guestOS, state: instance.stateBucket, network: network,
                guestAgent: guestAgent, isEphemeral: instance.hostState.ephemeralModeEnabled,
                hasSnapshots: instance.hasSnapshotsBesideBaseline)
        case .arriving:
            return VMLibraryFilter.Subject(
                guestOS: configuration.guestOS, state: .preparing, network: network,
                guestAgent: guestAgent, isEphemeral: false, hasSnapshots: false)
        }
    }
}
