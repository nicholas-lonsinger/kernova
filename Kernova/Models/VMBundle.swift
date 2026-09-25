import Foundation
import KernovaLogging

/// One VM bundle on disk: its state files — `config.json`, `host-state.json`,
/// `Snapshots/manifest.json` and `usb-accessories.json` — with the values last
/// committed to them, and its machine files — the snapshot directories, the
/// suspend slot, the firmware and platform files, and the in-bundle disks.
///
/// The only reader and writer of the state files, and the only writer of the
/// machine files. Built only from a ``VMBundleRead``, so it exists only for a
/// bundle already on disk, and each value it holds is one a coordinated read
/// found or a committed write left on disk: memory never holds a value disk
/// lacks.
///
/// A commit reads the file, applies its change to what the file holds, replaces
/// the file, and only then publishes the new value; one that throws leaves the
/// value as it was. The change runs inside the coordinated write, so it must be
/// pure — no UI, no suspension, no second access to this bundle.
///
/// A machine-file operation runs its file work off the main actor, through
/// ``VMBundleMachineFileWorking``.
@MainActor
@Observable
final class VMBundle {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMBundle")

    @ObservationIgnored private let files: VMBundleFiles
    @ObservationIgnored private let machineFiles: any VMBundleMachineFileWorking

    var url: URL { files.url }

    #if DEBUG
    /// What this bundle's files are read and written through.
    ///
    /// Test-only seam: a test registering a fixture VM with a library points
    /// the fixture's in-memory files at the library's storage through it.
    var fileAccessForTesting: any VMBundleFileAccessing { files.access }
    #endif

    private(set) var configuration: VMConfiguration
    private(set) var hostState: VMHostState
    private(set) var snapshotManifest: VMSnapshotManifest
    private(set) var usbPairings: USBAccessoryPairingSet

    init(_ read: VMBundleRead, machineFiles: any VMBundleMachineFileWorking) {
        files = read.files
        self.machineFiles = machineFiles
        configuration = read.configuration
        hostState = read.hostState
        snapshotManifest = read.snapshotManifest
        usbPairings = read.usbPairings
    }

    /// Sets a committed value only when it moved, so a no-op write wakes no
    /// observer.
    private func publish<Value: Equatable>(
        _ value: Value, to keyPath: ReferenceWritableKeyPath<VMBundle, Value>
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    // MARK: - State files

    /// Commits `change` to `config.json`; `key` confines the call to
    /// ``VMLibrary``, which owns the refusals a configuration write passes.
    func commitConfiguration(
        key _: VMLibrary.ConfigurationWriteKey, _ change: (inout VMConfiguration) throws -> Void
    ) throws {
        publish(try files.update(.configuration, change), to: \.configuration)
    }

    func commitHostState(_ change: (inout VMHostState) throws -> Void) throws {
        publish(try files.update(.hostState, change), to: \.hostState)
    }

    func commitSnapshotManifest(_ change: (inout VMSnapshotManifest) throws -> Void) throws {
        publish(try files.update(.snapshotManifest, change), to: \.snapshotManifest)
    }

    func commitUSBPairings(_ change: (inout USBAccessoryPairingSet) throws -> Void) throws {
        publish(try files.update(.usbPairings, change), to: \.usbPairings)
    }

    // MARK: - Machine files

    private func offMainActor<T: Sendable>(
        _ work: @escaping @Sendable (any VMBundleMachineFileWorking, URL) throws -> T
    ) async throws -> T {
        let machineFiles = machineFiles
        let url = url
        return try await Task.detached { try work(machineFiles, url) }.value
    }

    private func offMainActorInfallibly<T: Sendable>(
        _ work: @escaping @Sendable (any VMBundleMachineFileWorking, URL) -> T
    ) async -> T {
        let machineFiles = machineFiles
        let url = url
        return await Task.detached { work(machineFiles, url) }.value
    }

    // MARK: Snapshots

    /// Creates snapshot `id`'s directory holding `configuration`, answering
    /// where its saved state goes and which bundle files it copies.
    func prepareSnapshot(
        _ id: UUID, configuration: VMConfiguration
    ) async throws -> VMSnapshotCapturePlan {
        try await offMainActor {
            try $0.prepareSnapshot(bundleURL: $1, snapshotID: id, configuration: configuration)
        }
    }

    /// Clones `relativePaths` into snapshot `id`'s directory.
    func captureDisks(intoSnapshot id: UUID, relativePaths: [String]) async throws {
        try await offMainActor {
            try $0.captureDisks(bundleURL: $1, snapshotID: id, relativePaths: relativePaths)
        }
    }

    /// Clones the suspend slot into snapshot `id`'s own saved state, leaving
    /// the slot in place.
    func captureSuspendSlot(intoSnapshot id: UUID) async throws {
        try await offMainActor { try $0.captureSuspendSlot(bundleURL: $1, snapshotID: id) }
    }

    /// Removes snapshot `id`'s directory outright — a capture that failed
    /// partway, or one no manifest lists.
    func removeSnapshotDirectory(_ id: UUID) async {
        await offMainActorInfallibly { $0.removeSnapshotDirectory(bundleURL: $1, snapshotID: id) }
    }

    /// Moves snapshot `id`'s directory to the Trash.
    func discardSnapshot(_ id: UUID) async throws {
        try await offMainActor { try $0.discardSnapshot(bundleURL: $1, snapshotID: id) }
    }

    /// Bytes each snapshot the manifest lists occupies on disk.
    func snapshotSizes() async -> [UUID: UInt64] {
        let ids = snapshotManifest.snapshots.map(\.id)
        guard !ids.isEmpty else { return [:] }
        return await offMainActorInfallibly { $0.onDiskBytes(bundleURL: $1, snapshotIDs: ids) }
    }

    // MARK: Restore

    /// What snapshot `id` holds, checked complete; touches nothing in the
    /// bundle.
    func planRestore(fromSnapshot id: UUID, kind: VMSnapshotKind) async throws
        -> VMSnapshotRestorePlan
    {
        try await offMainActor { try $0.planRestore(bundleURL: $1, snapshotID: id, kind: kind) }
    }

    /// Clones what `plan` restores from snapshot `id` into the restore staging
    /// directory; touches nothing else in the bundle.
    func stageRestore(fromSnapshot id: UUID, plan: VMSnapshotRestorePlan) async throws {
        try await offMainActor { try $0.stageRestore(bundleURL: $1, snapshotID: id, plan: plan) }
    }

    /// Swaps the staged files into the bundle and removes the staging
    /// directory.
    func installRestore(_ plan: VMSnapshotRestorePlan) async throws {
        try await offMainActor { try $0.installRestore(bundleURL: $1, plan: plan) }
    }

    /// Removes the restore staging directory, if the bundle holds one.
    func discardRestoreStaging() async {
        await offMainActorInfallibly { $0.sweepRestoreStaging(bundleURL: $1) }
    }

    // MARK: Suspend slot

    /// Where the suspend slot lives — the URL VZ writes a save into and
    /// restores one from.
    var saveFileURL: URL { VMBundleLayout(bundleURL: url).saveFileURL }

    /// Removes the suspend slot, if the bundle holds one.
    ///
    /// Synchronous so a caller resting the VM can do both in one step. A
    /// removal the file system turned down leaves the slot in place and logs
    /// it; the caller reads the slot again to learn which happened.
    func removeSaveFile() {
        do {
            try machineFiles.removeSaveFile(bundleURL: url)
        } catch {
            #log(
                Self.logger, .warning,
                "Failed to remove the save file of '\(self.configuration.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Firmware and platform

    /// Creates the EFI variable store an EFI boot reads, unless the bundle
    /// already holds one.
    func ensureEFIVariableStore() async throws {
        try await offMainActor { try $0.ensureEFIVariableStore(bundleURL: $1) }
    }

    /// Writes the macOS platform files an install of `hardwareModel` boots
    /// from, answering the machine identifier the bundle now holds.
    func createMacPlatformFiles(hardwareModel: Data) async throws -> Data {
        try await offMainActor {
            try $0.createMacPlatformFiles(bundleURL: $1, hardwareModel: hardwareModel)
        }
    }

    // MARK: In-bundle disks

    /// Writes a new disk image of `sizeInGB` through `diskImages` at the
    /// in-bundle path `id` names, answering that path relative to the bundle.
    func createInternalDisk(
        id: UUID, sizeInGB: Int, using diskImages: any DiskImageProviding
    ) async throws -> String {
        let machineFiles = machineFiles
        let url = url
        return try await Task.detached {
            try await machineFiles.createInternalDisk(
                bundleURL: url, id: id, sizeInGB: sizeInGB, diskImages: diskImages)
        }.value
    }

    /// Moves the in-bundle disk at `relativePath` to the Trash.
    func trashInternalDisk(atRelativePath relativePath: String) async throws {
        try await offMainActor { try $0.trashInternalDisk(bundleURL: $1, relativePath: relativePath) }
    }
}
