import Foundation
@testable import Kernova

/// Registers a `VMInstance` the way `VMCommandCoreTests` and
/// `VMCapabilityCatalogTests` both need one built.
@MainActor
enum RegisteredVMInstanceFixture {
    /// Wired the way every real construction site is, so the per-instance
    /// hooks a verb answers — the power-off that starts an Ephemeral revert,
    /// above all — are actually connected, and with its bundle in `storage`.
    ///
    /// `snapshots` seeds the manifest, and the bundle's machine files go
    /// through `library`'s. `mutate` runs after networking is turned off, so it
    /// can turn it back on.
    @discardableResult
    static func register(
        name: String, phase: VMLifecyclePhase, guestOS: VMGuestOS, snapshots: [VMSnapshot] = [],
        library: VMLibrary, storage: MockVMStorageService, preferences: AppPreferences,
        hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(
            name: name, guestOS: guestOS, phase: phase, preferences: preferences, hostState: hostState,
            snapshots: VMSnapshotManifest(snapshots: snapshots), files: storage.files,
            bundleFactory: library.bundleFactory,
            mutate: {
                $0.networkEnabled = false
                mutate(&$0)
            })
        library.register(instance, storage: storage)
        return instance
    }
}
