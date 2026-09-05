import AppIntents
import CoreSpotlight
import Foundation

/// Where VMs are written so Spotlight can find them by name.
protocol VMEntityIndexing: Sendable {
    /// Writes `vms`, replacing whatever was held for the same identifiers.
    func index(_ vms: [VMEntity]) async throws

    /// Drops the records the VMs `ids` names.
    func remove(_ ids: [UUID]) async throws
}

/// The system Spotlight index, which is what Spotlight search matches a VM
/// name in.
struct SpotlightVMEntityIndex: VMEntityIndexing {
    func index(_ vms: [VMEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(vms)
    }

    func remove(_ ids: [UUID]) async throws {
        try await CSSearchableIndex.default().deleteAppEntities(
            identifiedBy: ids, ofType: VMEntity.self)
    }
}
