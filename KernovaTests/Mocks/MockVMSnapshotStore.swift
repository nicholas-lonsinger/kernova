import Foundation

@testable import Kernova

/// In-memory mock for `VMSnapshotStoring` that records manifest writes and file
/// operations without touching disk.
///
/// Lock-based because production reads and writes it from `Task.detached`, so
/// calls arrive off the test's isolation.
final class MockVMSnapshotStore: VMSnapshotStoring, @unchecked Sendable {
    private struct State {
        var manifests: [URL: VMSnapshotManifest] = [:]
        var capturedPaths: [UUID: [String]] = [:]
        var capturedConfigurations: [UUID: VMConfiguration] = [:]
        var restoredIDs: [UUID] = []
        var restoredConfigurations: [UUID: VMConfiguration] = [:]
        var discardedIDs: [UUID] = []
        var removedDirectoryIDs: [UUID] = []
        var sizes: [UUID: UInt64] = [:]
        var saveManifestError: (any Error)?
        var prepareError: (any Error)?
        var captureError: (any Error)?
        var planRestoreError: (any Error)?
        var restoreError: (any Error)?
        var discardError: (any Error)?
    }

    private let lock = NSLock()
    private var state = State()

    // MARK: - Seeding

    /// Seeds the manifest a bundle answers with.
    func setManifest(_ manifest: VMSnapshotManifest, for bundleURL: URL) {
        lock.withLock { state.manifests[bundleURL] = manifest }
    }

    /// Seeds the on-disk size one snapshot reports.
    func setSize(_ bytes: UInt64, for snapshotID: UUID) {
        lock.withLock { state.sizes[snapshotID] = bytes }
    }

    /// Seeds the configuration one snapshot captured, as `prepareSnapshot`
    /// records it — what a revert reads back and installs.
    func setCapturedConfiguration(_ configuration: VMConfiguration, for snapshotID: UUID) {
        lock.withLock { state.capturedConfigurations[snapshotID] = configuration }
    }

    // MARK: - Recorded calls

    func manifest(for bundleURL: URL) -> VMSnapshotManifest? {
        lock.withLock { state.manifests[bundleURL] }
    }
    /// Bundle-relative paths passed to `captureDisks`, keyed by snapshot id.
    var capturedPaths: [UUID: [String]] { lock.withLock { state.capturedPaths } }
    /// Configurations passed to `prepareSnapshot`, keyed by snapshot id — what
    /// the snapshot's own `config.json` would hold.
    var capturedConfigurations: [UUID: VMConfiguration] {
        lock.withLock { state.capturedConfigurations }
    }
    /// Configurations written back over the bundle's, keyed by snapshot id.
    var restoredConfigurations: [UUID: VMConfiguration] {
        lock.withLock { state.restoredConfigurations }
    }
    var restoredIDs: [UUID] { lock.withLock { state.restoredIDs } }
    var discardedIDs: [UUID] { lock.withLock { state.discardedIDs } }
    var removedDirectoryIDs: [UUID] { lock.withLock { state.removedDirectoryIDs } }

    // MARK: - Error injection

    var saveManifestError: (any Error)? {
        get { lock.withLock { state.saveManifestError } }
        set { lock.withLock { state.saveManifestError = newValue } }
    }
    var prepareError: (any Error)? {
        get { lock.withLock { state.prepareError } }
        set { lock.withLock { state.prepareError = newValue } }
    }
    var captureError: (any Error)? {
        get { lock.withLock { state.captureError } }
        set { lock.withLock { state.captureError = newValue } }
    }
    var planRestoreError: (any Error)? {
        get { lock.withLock { state.planRestoreError } }
        set { lock.withLock { state.planRestoreError = newValue } }
    }
    var restoreError: (any Error)? {
        get { lock.withLock { state.restoreError } }
        set { lock.withLock { state.restoreError = newValue } }
    }
    var discardError: (any Error)? {
        get { lock.withLock { state.discardError } }
        set { lock.withLock { state.discardError = newValue } }
    }

    // MARK: - VMSnapshotStoring

    func loadManifest(bundleURL: URL) -> VMSnapshotManifest {
        lock.withLock { state.manifests[bundleURL] ?? VMSnapshotManifest() }
    }

    func saveManifest(_ manifest: VMSnapshotManifest, bundleURL: URL) throws {
        try lock.withLock {
            if let error = state.saveManifestError { throw error }
            state.manifests[bundleURL] = manifest
        }
    }

    func prepareSnapshot(
        bundleURL: URL, snapshotID: UUID, configuration: VMConfiguration
    ) throws -> VMSnapshotCapturePlan {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        return try lock.withLock {
            if let error = state.prepareError { throw error }
            state.capturedConfigurations[snapshotID] = configuration
            return VMSnapshotCapturePlan(
                saveFileURL: layout.snapshotLayout(id: snapshotID).saveFileURL,
                relativePaths: VMSnapshotStore.capturedRelativePaths(
                    for: configuration, layout: layout))
        }
    }

    func captureDisks(bundleURL: URL, snapshotID: UUID, relativePaths: [String]) throws {
        try lock.withLock {
            if let error = state.captureError { throw error }
            state.capturedPaths[snapshotID] = relativePaths
        }
    }

    /// Answers the plan for a snapshot this store captured or was seeded with;
    /// a snapshot with no recorded configuration refuses, exactly as a snapshot
    /// directory missing its `config.json` does.
    func planRestore(bundleURL: URL, snapshotID: UUID) throws -> VMSnapshotRestorePlan {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        return try lock.withLock {
            if let error = state.planRestoreError { throw error }
            guard let configuration = state.capturedConfigurations[snapshotID] else {
                throw VMSnapshotError.snapshotMissingConfiguration
            }
            return VMSnapshotRestorePlan(
                configuration: configuration,
                relativePaths: VMSnapshotStore.capturedRelativePaths(
                    for: configuration, layout: layout))
        }
    }

    func restore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws {
        try lock.withLock {
            if let error = state.restoreError { throw error }
            state.restoredIDs.append(snapshotID)
            state.restoredConfigurations[snapshotID] = plan.configuration
        }
    }

    func discardSnapshot(bundleURL: URL, snapshotID: UUID) throws {
        try lock.withLock {
            if let error = state.discardError { throw error }
            state.discardedIDs.append(snapshotID)
        }
    }

    func removeSnapshotDirectory(bundleURL: URL, snapshotID: UUID) {
        lock.withLock { state.removedDirectoryIDs.append(snapshotID) }
    }

    func onDiskBytes(bundleURL: URL, snapshotIDs: [UUID]) -> [UUID: UInt64] {
        lock.withLock {
            var sizes: [UUID: UInt64] = [:]
            for id in snapshotIDs { sizes[id] = state.sizes[id] ?? 0 }
            return sizes
        }
    }
}
