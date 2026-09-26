import Foundation
import KernovaLogging

/// One VM bundle on disk: its state files — `config.json`, `host-state.json`,
/// `Snapshots/manifest.json` and `usb-accessories.json` — with the values last
/// committed to them, and its machine files — the snapshot directories and the
/// restore staging, the suspend slot, the firmware and platform files, and the
/// in-bundle disks.
///
/// The only reader and writer of the state files, and the only writer of the
/// machine files. Built only by a ``Factory`` from a ``VMBundleRead``, so it
/// exists only for a bundle already on disk, and each value it holds is one a
/// coordinated read found or a committed write left on disk: memory never
/// holds a value disk lacks.
///
/// A commit reads the file, applies its change to what the file holds, replaces
/// the file, and only then publishes the new value; one that throws leaves the
/// value as it was. The change runs inside the coordinated write, so it must be
/// pure — no UI, no suspension, no second access to this bundle. Commits are
/// reached only through ``StateFiles``.
///
/// A machine-file operation runs its file work off the main actor, through
/// ``VMBundleMachineFileWorking``. Every one that changes the bundle is
/// reached only through ``MachineFiles``.
@MainActor
@Observable
final class VMBundle {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMBundle")

    @ObservationIgnored private let files: VMBundleFiles
    @ObservationIgnored private let fileWorker: any VMBundleMachineFileWorking
    @ObservationIgnored fileprivate var configurationPolicy: any VMConfigurationPolicy

    var url: URL { files.url }

    #if DEBUG
    /// What this bundle's files are read and written through.
    ///
    /// Test-only seam: a test registering a fixture VM with a library points
    /// the fixture's in-memory files at the library's storage through it.
    var fileAccessForTesting: any VMBundleFileAccessing { files.access }

    /// Makes `policy` the one this bundle's configuration commits answer to.
    ///
    /// Test-only seam: a fixture built before the library that admits it
    /// answers to that library's policy, as a bundle the library built does.
    func answerToConfigurationPolicyForTesting(_ policy: any VMConfigurationPolicy) {
        configurationPolicy = policy
    }
    #endif

    private(set) var configuration: VMConfiguration
    private(set) var hostState: VMHostState
    private(set) var snapshotManifest: VMSnapshotManifest
    private(set) var usbPairings: USBAccessoryPairingSet

    fileprivate init(
        _ read: VMBundleRead, machineFiles: any VMBundleMachineFileWorking,
        configurationPolicy: any VMConfigurationPolicy
    ) {
        files = read.files
        fileWorker = machineFiles
        self.configurationPolicy = configurationPolicy
        configuration = read.configuration
        hostState = read.hostState
        snapshotManifest = read.snapshotManifest
        usbPairings = read.usbPairings
    }

    /// What builds every ``VMBundle``, holding the machine-file work they share
    /// and the configuration policy every configuration commit answers to,
    /// where nothing else can reach them.
    ///
    /// Its one other operation is the launch reclaim of restore staging, which
    /// runs before any bundle is built.
    struct Factory: Sendable {
        private let machineFiles: any VMBundleMachineFileWorking
        private let configurationPolicy: any VMConfigurationPolicy

        init(
            machineFiles: any VMBundleMachineFileWorking,
            configurationPolicy: any VMConfigurationPolicy
        ) {
            self.machineFiles = machineFiles
            self.configurationPolicy = configurationPolicy
        }

        @MainActor
        func make(_ read: VMBundleRead) -> VMBundle {
            VMBundle(read, machineFiles: machineFiles, configurationPolicy: configurationPolicy)
        }

        /// Removes the restore staging directory an interrupted revert left in
        /// each of `bundleURLs`.
        ///
        /// Blocks on the filesystem. Only for bundles no ``VMBundle`` of this
        /// run holds yet, so no revert can be staging there.
        func reclaimRestoreStaging(in bundleURLs: [URL]) {
            for bundleURL in bundleURLs {
                machineFiles.sweepRestoreStaging(bundleURL: bundleURL)
            }
        }
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

    fileprivate func commitConfiguration(_ change: (inout VMConfiguration) throws -> Void) throws {
        publish(try files.update(.configuration, change), to: \.configuration)
    }

    fileprivate func commitHostState(_ change: (inout VMHostState) throws -> Void) throws {
        publish(try files.update(.hostState, change), to: \.hostState)
    }

    fileprivate func commitSnapshotManifest(
        _ change: (inout VMSnapshotManifest) throws -> Void
    ) throws {
        publish(try files.update(.snapshotManifest, change), to: \.snapshotManifest)
    }

    fileprivate func commitUSBPairings(
        _ change: (inout USBAccessoryPairingSet) throws -> Void
    ) throws {
        publish(try files.update(.usbPairings, change), to: \.usbPairings)
    }

    // MARK: - Machine files

    fileprivate func offMainActor<T: Sendable>(
        _ work: @escaping @Sendable (any VMBundleMachineFileWorking, URL) throws -> T
    ) async throws -> T {
        let fileWorker = fileWorker
        let url = url
        return try await Task.detached { try work(fileWorker, url) }.value
    }

    fileprivate func offMainActorInfallibly<T: Sendable>(
        _ work: @escaping @Sendable (any VMBundleMachineFileWorking, URL) -> T
    ) async -> T {
        let fileWorker = fileWorker
        let url = url
        return await Task.detached { work(fileWorker, url) }.value
    }

    /// Bytes each snapshot the manifest lists occupies on disk.
    func snapshotSizes() async -> [UUID: UInt64] {
        let ids = snapshotManifest.snapshots.map(\.id)
        guard !ids.isEmpty else { return [:] }
        return await offMainActorInfallibly { $0.onDiskBytes(bundleURL: $1, snapshotIDs: ids) }
    }
}

/// What a configuration commit answers to beyond its permit: the refusals and
/// the follow-through that span the library a VM belongs to.
@MainActor
protocol VMConfigurationPolicy: AnyObject, Sendable {
    /// Why moving `instance`'s configuration from `old` — what `config.json`
    /// holds — to `new` under `authority` is refused, or `nil` when it is not.
    ///
    /// Runs inside the coordinated write, so it must be pure.
    func refusal(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration,
        under authority: VMEditPermit.Authority
    ) -> (any Error)?

    /// Carries a commit that moved `instance`'s configuration from `old` to
    /// `new` to whatever acts on it.
    func committed(on instance: VMInstance, from old: VMConfiguration, to new: VMConfiguration)
}

extension VMBundle {
    /// One VM's state-file commits — reachable only as ``VMEditPermit/bundle``,
    /// so every write holds a permit admission minted, on that VM's own bundle.
    ///
    /// Every commit is refused, leaving its file as it was, when it moves a
    /// field its permit's authority may not write
    /// (``VMStateFieldRefusal``): what a write changes is checked against
    /// what the file holds, never trusted from the caller.
    ///
    /// Every call commits to the bundle the VM lives in at that moment, as
    /// ``MachineFiles`` does.
    @MainActor
    struct StateFiles: ~Copyable, Sendable {
        private let owner: VMInstance
        private let authority: VMEditPermit.Authority

        /// `key` is what only ``VMEditPermit`` mints, over its own VM.
        init(
            of owner: VMInstance, authority: VMEditPermit.Authority,
            _ key: VMEditPermit.StateFilesKey
        ) {
            self.owner = owner
            self.authority = authority
        }

        private var bundle: VMBundle { owner.bundle }

        /// Commits `change` to `config.json`, refused by the field check and
        /// then by the bundle's ``VMConfigurationPolicy`` inside the write,
        /// and carried to that policy once it moved what memory holds.
        func commitConfiguration(_ change: (inout VMConfiguration) throws -> Void) throws {
            let bundle = bundle
            let policy = bundle.configurationPolicy
            let old = bundle.configuration
            try bundle.commitConfiguration { config in
                let onDisk = config
                try change(&config)
                guard config != onDisk else { return }
                try requireWritable(VMConfiguration.fieldClasses, from: onDisk, to: config)
                if let refusal = policy.refusal(
                    on: owner, movingFrom: onDisk, to: config, under: authority)
                {
                    throw refusal
                }
            }
            let new = bundle.configuration
            if new != old {
                policy.committed(on: owner, from: old, to: new)
            }
        }

        func commitHostState(_ change: (inout VMHostState) throws -> Void) throws {
            try bundle.commitHostState { hostState in
                let onDisk = hostState
                try change(&hostState)
                try requireWritable(VMHostState.fieldClasses, from: onDisk, to: hostState)
            }
        }

        func commitSnapshotManifest(_ change: (inout VMSnapshotManifest) throws -> Void) throws {
            try bundle.commitSnapshotManifest { manifest in
                let onDisk = manifest
                try change(&manifest)
                try requireWritable(VMSnapshotManifest.fieldClasses, from: onDisk, to: manifest)
            }
        }

        func commitUSBPairings(_ change: (inout USBAccessoryPairingSet) throws -> Void) throws {
            try bundle.commitUSBPairings { pairings in
                let onDisk = pairings
                try change(&pairings)
                try requireWritable(USBAccessoryPairingSet.fieldClasses, from: onDisk, to: pairings)
            }
        }

        private func requireWritable<Root>(
            _ classification: VMStateFieldClasses<Root>, from old: Root, to new: Root
        ) throws {
            let refused = classification.refused(from: old, to: new, by: authority)
            guard refused.isEmpty else { throw VMStateFieldRefusal(fields: refused) }
        }
    }

    /// One VM's machine-file operations — reachable only as
    /// ``VMOperationContext/bundle``, so only an operation holding the VM runs
    /// them, and only on that VM's own bundle.
    ///
    /// Every call acts on the bundle the VM lives in at that moment, so a
    /// bundle moved in Finder mid-operation is followed to where it now is.
    ///
    /// Non-copyable, and held inside the context, so it cannot outlive the
    /// operation either.
    @MainActor
    struct MachineFiles: ~Copyable, Sendable {
        private let owner: VMInstance

        /// `key` is what only ``VMOperationContext`` mints, over its own VM.
        init(of owner: VMInstance, _ key: VMOperationContext.MachineFilesKey) {
            self.owner = owner
        }

        private var bundle: VMBundle { owner.bundle }

        /// Where the bundle lives — the directory a configuration build for
        /// this operation reads the disks and the firmware and platform files
        /// from.
        var url: URL { bundle.url }

        // MARK: Suspend slot

        /// Where the suspend slot lives — the URL VZ writes a save into and
        /// restores one from.
        var saveFileURL: URL { VMBundleLayout(bundleURL: bundle.url).saveFileURL }

        /// Whether the bundle holds a suspend slot.
        var hasSaveFile: Bool { VMBundleLayout(bundleURL: bundle.url).hasSaveFile }

        /// Removes the suspend slot, if the bundle holds one.
        ///
        /// Synchronous so a caller resting the VM can do both in one step. A
        /// removal the file system turned down leaves the slot in place and
        /// logs it; the caller reads ``hasSaveFile`` to learn which happened.
        func removeSaveFile() {
            bundle.removeSaveFileLoggingRefusal()
        }

        // MARK: Snapshots

        /// Creates snapshot `id`'s directory holding `configuration`, answering
        /// where its saved state goes and which bundle files it copies.
        func prepareSnapshot(
            _ id: UUID, configuration: VMConfiguration
        ) async throws -> VMSnapshotCapturePlan {
            try await bundle.offMainActor {
                try $0.prepareSnapshot(bundleURL: $1, snapshotID: id, configuration: configuration)
            }
        }

        /// Clones `relativePaths` into snapshot `id`'s directory.
        func captureDisks(intoSnapshot id: UUID, relativePaths: [String]) async throws {
            try await bundle.offMainActor {
                try $0.captureDisks(bundleURL: $1, snapshotID: id, relativePaths: relativePaths)
            }
        }

        /// Clones the suspend slot into snapshot `id`'s own saved state,
        /// leaving the slot in place.
        func captureSuspendSlot(intoSnapshot id: UUID) async throws {
            try await bundle.offMainActor { try $0.captureSuspendSlot(bundleURL: $1, snapshotID: id) }
        }

        /// Removes snapshot `id`'s directory outright — a capture that failed
        /// partway, or one no manifest lists.
        func removeSnapshotDirectory(_ id: UUID) async {
            await bundle.offMainActorInfallibly {
                $0.removeSnapshotDirectory(bundleURL: $1, snapshotID: id)
            }
        }

        /// Moves snapshot `id`'s directory to the Trash.
        func discardSnapshot(_ id: UUID) async throws {
            try await bundle.offMainActor { try $0.discardSnapshot(bundleURL: $1, snapshotID: id) }
        }

        // MARK: Restore

        /// What snapshot `id` holds, checked complete; touches nothing in the
        /// bundle.
        func planRestore(
            fromSnapshot id: UUID, kind: VMSnapshotKind
        ) async throws -> VMSnapshotRestorePlan {
            try await bundle.offMainActor {
                try $0.planRestore(bundleURL: $1, snapshotID: id, kind: kind)
            }
        }

        /// Clones what `plan` restores from snapshot `id` into the restore
        /// staging directory; touches nothing else in the bundle.
        func stageRestore(fromSnapshot id: UUID, plan: VMSnapshotRestorePlan) async throws {
            try await bundle.offMainActor {
                try $0.stageRestore(bundleURL: $1, snapshotID: id, plan: plan)
            }
        }

        /// Swaps the staged files into the bundle and removes the staging
        /// directory.
        func installRestore(_ plan: VMSnapshotRestorePlan) async throws {
            try await bundle.offMainActor { try $0.installRestore(bundleURL: $1, plan: plan) }
        }

        /// Removes the restore staging directory, if the bundle holds one.
        func discardRestoreStaging() async {
            await bundle.offMainActorInfallibly { $0.sweepRestoreStaging(bundleURL: $1) }
        }

        // MARK: In-bundle disks

        /// Writes a new disk image of `sizeInGB` through `diskImages` at the
        /// in-bundle path `id` names, answering that path relative to the
        /// bundle.
        func createInternalDisk(
            id: UUID, sizeInGB: Int, using diskImages: any DiskImageProviding
        ) async throws -> String {
            try await bundle.createInternalDisk(id: id, sizeInGB: sizeInGB, using: diskImages)
        }

        /// Moves the in-bundle disk at `relativePath` to the Trash.
        func trashInternalDisk(atRelativePath relativePath: String) async throws {
            try await bundle.offMainActor {
                try $0.trashInternalDisk(bundleURL: $1, relativePath: relativePath)
            }
        }

        // MARK: Firmware and platform

        /// Creates the EFI variable store an EFI boot reads, unless the bundle
        /// already holds one.
        func ensureEFIVariableStore() async throws {
            try await bundle.offMainActor { try $0.ensureEFIVariableStore(bundleURL: $1) }
        }

        /// Writes the macOS platform files an install of `hardwareModel` boots
        /// from, answering the machine identifier the bundle now holds.
        func createMacPlatformFiles(hardwareModel: Data) async throws -> Data {
            try await bundle.offMainActor {
                try $0.createMacPlatformFiles(bundleURL: $1, hardwareModel: hardwareModel)
            }
        }
    }

    fileprivate func createInternalDisk(
        id: UUID, sizeInGB: Int, using diskImages: any DiskImageProviding
    ) async throws -> String {
        let fileWorker = fileWorker
        let url = url
        return try await Task.detached {
            try await fileWorker.createInternalDisk(
                bundleURL: url, id: id, sizeInGB: sizeInGB, diskImages: diskImages)
        }.value
    }

    fileprivate func removeSaveFileLoggingRefusal() {
        do {
            try fileWorker.removeSaveFile(bundleURL: url)
        } catch {
            #log(
                Self.logger, .warning,
                "Failed to remove the save file of '\(self.configuration.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
