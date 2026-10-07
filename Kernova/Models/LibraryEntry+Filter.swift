import Foundation
import KernovaKit

extension VMInstance {
    /// Whether the bundle holds a snapshot other than the Ephemeral Mode
    /// baseline — what the Has Snapshots filter and query read.
    var hasSnapshotsBesideBaseline: Bool {
        snapshotManifest.snapshots.contains { !isEphemeralBaseline($0) }
    }

    /// Where this VM's guest agent stands against `bundledVersion`, `nil` for
    /// a guest no Kernova agent runs in.
    func guestAgentBucket(bundledVersion: String?) -> VMGuestAgentBucket? {
        guard configuration.guestOS == .macOS else { return nil }
        return VMGuestAgentBucket(lastSeenVersion: lastSeenAgentVersion, bundledVersion: bundledVersion)
    }
}

extension LibraryEntry {
    /// What a ``VMLibraryFilter`` reads of this entry. An arrival is
    /// preparing, with no session, no Ephemeral Mode and no snapshots.
    func filterSubject(bundledAgentVersion: String?) -> VMLibraryFilter.Subject {
        switch self {
        case .vm(let instance):
            VMLibraryFilter.Subject(
                guestOS: instance.configuration.guestOS,
                state: VMStateBucket(instance.status, heldByAnotherCopy: instance.heldByAnotherCopy),
                network: NetworkModeChoice(instance.configuration),
                guestAgent: instance.guestAgentBucket(bundledVersion: bundledAgentVersion),
                isEphemeral: instance.hostState.ephemeralModeEnabled,
                hasSnapshots: instance.hasSnapshotsBesideBaseline)
        case .arriving(let arrival):
            VMLibraryFilter.Subject(
                guestOS: arrival.configuration.guestOS,
                state: .preparing,
                network: NetworkModeChoice(arrival.configuration),
                guestAgent: arrival.configuration.guestOS == .macOS
                    ? VMGuestAgentBucket(
                        lastSeenVersion: arrival.configuration.lastSeenAgentVersion,
                        bundledVersion: bundledAgentVersion)
                    : nil,
                isEphemeral: false,
                hasSnapshots: false)
        }
    }
}
