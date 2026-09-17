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

/// Where the identifiers already written to the index are recorded.
@MainActor
protocol VMIndexRecording: AnyObject {
    /// Which VMs the index is believed to hold, as of the last write that
    /// landed.
    ///
    /// Persisted because it is what a later launch prunes against: the index
    /// outlives the process, so a VM deleted while Kernova was not running is
    /// only findable-but-gone until some run notices it is no longer in the
    /// library.
    var indexedVMIDs: Set<UUID> { get set }
}

/// The record `UserDefaults` holds, which is the one a later launch reads back.
@MainActor
final class DefaultsVMIndexRecord: VMIndexRecording {
    /// The literal `UserDefaults` key the identifiers are stored under.
    private static let key = "SpotlightIndexedVMIDs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var indexedVMIDs: Set<UUID> {
        get {
            Set(
                (defaults.stringArray(forKey: Self.key) ?? [])
                    .compactMap(UUID.init(uuidString:)))
        }
        set { defaults.set(newValue.map(\.uuidString), forKey: Self.key) }
    }
}
