import Foundation
@testable import Kernova

/// Records each live share swap, standing in for the running VM a real
/// install needs, and holds the scopes each swap hands it the way a session
/// does: until a later swap releases their share.
@MainActor
final class MockLiveDirectorySharing: LiveDirectorySharing {
    struct Install: Equatable {
        let share: MacOSDirectoryShare
        let opened: Set<UUID>
        let released: Set<UUID>
        let sessionID: UUID
    }

    private(set) var installs: [Install] = []
    private var held: [UUID: ScopedAccess] = [:]

    /// The shares whose scopes the session holds now.
    var heldScopeIDs: Set<UUID> { Set(held.keys) }

    func install(
        _ share: MacOSDirectoryShare, holding opened: [UUID: ScopedAccess],
        releasing released: Set<UUID>, on instance: VMInstance, for sessionID: UUID
    ) {
        installs.append(
            Install(
                share: share, opened: Set(opened.keys), released: released, sessionID: sessionID))
        held.merge(opened) { _, new in new }
        for id in released { held.removeValue(forKey: id)?.release() }
    }
}
