import Foundation
@testable import Kernova

/// Registers a `VMInstance` the way `VMCommandCoreTests` and
/// `VMCapabilityCatalogTests` both need one built.
@MainActor
enum RegisteredVMInstanceFixture {
    /// Wired the way every real construction site is, so the per-instance
    /// hooks a verb answers — the power-off that starts an Ephemeral revert,
    /// above all — are actually connected.
    ///
    /// `snapshots` seeds a non-empty manifest *after* `wirePersistence`, which
    /// overwrites `snapshotManifest` from the (empty, unseeded) mock store's
    /// `loadManifest`.
    @discardableResult
    static func register(
        name: String, phase: VMLifecyclePhase, guestOS: VMGuestOS, snapshots: [VMSnapshot] = [],
        library: VMLibrary, storage: MockVMStorageService, preferences: AppPreferences
    ) -> VMInstance {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        config.networkEnabled = false
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, phase: phase, preferences: preferences)
        storage.bundles[bundleURL] = config
        library.wirePersistence(for: instance)
        if !snapshots.isEmpty {
            instance.snapshotManifest = VMSnapshotManifest(snapshots: snapshots)
        }
        library.instances.append(instance)
        return instance
    }
}
