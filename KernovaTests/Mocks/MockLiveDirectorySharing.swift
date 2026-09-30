import Foundation
@testable import Kernova

/// Records each live share swap, standing in for the running VM a real
/// install needs.
@MainActor
final class MockLiveDirectorySharing: LiveDirectorySharing {
    struct Install: Equatable {
        let share: MacOSDirectoryShare
        let opened: Set<UUID>
        let released: Set<UUID>
        let sessionID: UUID
    }

    private(set) var installs: [Install] = []

    func install(
        _ share: MacOSDirectoryShare, holding opened: [UUID: ScopedAccess],
        releasing released: Set<UUID>, on instance: VMInstance, for sessionID: UUID
    ) {
        installs.append(
            Install(
                share: share, opened: Set(opened.keys), released: released, sessionID: sessionID))
        opened.values.forEach { $0.release() }
    }
}
