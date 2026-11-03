import Foundation
import KernovaAgentHost
import KernovaCommandModel

/// What one scope's agent reported on a VM: the version it shows, and the payload it runs, by the SHA-256 the
/// agent hub judges it current by.
package struct GuestAgentSighting: Equatable, Sendable {
    /// The version label it reported.
    package var versionLabel: String
    /// The SHA-256 of the payload it claimed; `nil` for a record kept without one.
    package var payloadHash: Data?

    package init(versionLabel: String, payloadHash: Data?) {
        self.versionLabel = versionLabel
        self.payloadHash = payloadHash
    }

    /// What `peer` reported.
    init(_ peer: PeerSummary) {
        self.init(versionLabel: peer.versionLabel, payloadHash: peer.payloadHash)
    }
}

extension VMConfiguration {
    /// What `scope`'s agent last reported on this VM, as recorded; `nil` when no run recorded one.
    func lastSeenAgent(_ scope: GuestAgentScope) -> GuestAgentSighting? {
        switch scope {
        case .login:
            lastSeenAgentVersion.map { GuestAgentSighting(versionLabel: $0, payloadHash: lastSeenAgentPayloadHash) }
        case .system:
            lastSeenSystemAgentVersion.map {
                GuestAgentSighting(versionLabel: $0, payloadHash: lastSeenSystemAgentPayloadHash)
            }
        }
    }

    /// Records `sighting` as what `scope`'s agent last reported on this VM; `nil` clears the record.
    mutating func recordLastSeenAgent(_ sighting: GuestAgentSighting?, _ scope: GuestAgentScope) {
        switch scope {
        case .login:
            lastSeenAgentVersion = sighting?.versionLabel
            lastSeenAgentPayloadHash = sighting?.payloadHash
        case .system:
            lastSeenSystemAgentVersion = sighting?.versionLabel
            lastSeenSystemAgentPayloadHash = sighting?.payloadHash
        }
    }
}
