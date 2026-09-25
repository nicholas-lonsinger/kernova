import Foundation
import KernovaLogging
import Virtualization

/// The file operations behind a VM bundle's machine files: the snapshot
/// directories inside `Snapshots/` — one per snapshot, holding its VZ saved
/// state, the configuration it was captured under and copy-on-write disk
/// copies — the suspend slot, the firmware and platform files, and the
/// in-bundle disks.
///
/// `VMBundleLayout` owns the names; this owns the file operations.
struct VMBundleMachineFiles: VMBundleMachineFileWorking {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMBundleMachineFiles")

    /// The operations a test must not run for real: trashing moves a file into
    /// the user's own Trash. Every other file operation here runs against real
    /// files, which is what this type's tests exercise.
    private let fileSystem: any FileSystemOperating

    init(fileSystem: any FileSystemOperating) {
        self.fileSystem = fileSystem
    }

    // MARK: - Captured payload

    /// The bundle-relative paths a snapshot captures alongside the saved state.
    ///
    /// Every file the guest writes through that lives in the bundle: the disks
    /// it boots and stores data on, plus the firmware state VZ mutates
    /// (`AuxiliaryStorage` on macOS, `EFIVariableStore` on EFI Linux). The
    /// bundle's identity files (`HardwareModel`, `MachineIdentifier`) are
    /// absent — they never change, and a revert must not hand the VM a
    /// different identity.
    ///
    /// External disks are not captured: they are user-owned files outside the
    /// bundle, and copying them would double storage the user placed elsewhere
    /// on purpose.
    ///
    /// `layout` is the directory the firmware files are looked for in — the VM's
    /// bundle while capturing, the snapshot's own directory while working out
    /// what it holds.
    static func capturedRelativePaths(
        for configuration: VMConfiguration, layout: VMBundleLayout
    ) -> [String] {
        let disks = configuration.effectiveStorageDisks(layout: layout)
        var paths = disks.filter(\.isInternal).map(\.path)
        for firmware in ["AuxiliaryStorage", "EFIVariableStore"] {
            let url = layout.bundleURL.appendingPathComponent(firmware)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                paths.append(firmware)
            }
        }
        return paths
    }

    // MARK: - Capture

    func prepareSnapshot(
        bundleURL: URL, snapshotID: UUID, configuration: VMConfiguration
    ) throws -> VMSnapshotCapturePlan {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let snapshotLayout = layout.snapshotLayout(id: snapshotID)
        try FileManager.default.createDirectory(
            at: snapshotLayout.bundleURL, withIntermediateDirectories: true)
        let data = try VMConfiguration.makeJSONEncoder().encode(configuration)
        try data.write(to: snapshotLayout.configURL, options: .atomic)
        return VMSnapshotCapturePlan(
            saveFileURL: snapshotLayout.saveFileURL,
            relativePaths: Self.capturedRelativePaths(for: configuration, layout: layout))
    }

    func captureDisks(bundleURL: URL, snapshotID: UUID, relativePaths: [String]) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let destinationLayout = layout.snapshotLayout(id: snapshotID)
        let manager = FileManager.default
        for relativePath in relativePaths {
            let source = layout.bundleURL.appendingPathComponent(relativePath)
            guard manager.fileExists(atPath: source.path(percentEncoded: false)) else {
                throw VMSnapshotError.captureSourceMissing(relativePath)
            }
            let destination = destinationLayout.bundleURL.appendingPathComponent(relativePath)
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Same volume, so APFS clones the file rather than duplicating its
            // blocks — the copy shares them with the VM's disk until either
            // side writes.
            try manager.copyItem(at: source, to: destination)
        }
    }

    func captureSuspendSlot(bundleURL: URL, snapshotID: UUID) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let destinationLayout = layout.snapshotLayout(id: snapshotID)
        let manager = FileManager.default
        guard manager.fileExists(atPath: layout.saveFileURL.path(percentEncoded: false)) else {
            throw VMSnapshotError.captureSourceMissing(layout.saveFileURL.lastPathComponent)
        }
        // Same volume, so APFS clones the file rather than duplicating its
        // blocks — the copy shares them with the bundle's suspend slot until
        // either side writes.
        try manager.copyItem(at: layout.saveFileURL, to: destinationLayout.saveFileURL)
    }

    // MARK: - Restore

    /// The files a revert writes back, taken from the configuration the capture
    /// was made under — so they are the disks the snapshot holds rather than the
    /// ones the VM configures now.
    ///
    /// Read-only, and throws on an incomplete snapshot, so a caller can run it
    /// while the VM is still live.
    ///
    /// `kind` comes from the manifest rather than from whether a saved state is
    /// on disk: a warm snapshot whose saved state was lost has to keep refusing,
    /// not quietly restore as a cold one.
    func planRestore(
        bundleURL: URL, snapshotID: UUID, kind: VMSnapshotKind
    ) throws -> VMSnapshotRestorePlan {
        let sourceLayout = VMBundleLayout(bundleURL: bundleURL).snapshotLayout(id: snapshotID)
        let manager = FileManager.default

        if kind == .warm,
            !manager.fileExists(atPath: sourceLayout.saveFileURL.path(percentEncoded: false))
        {
            throw VMSnapshotError.snapshotMissingSavedState
        }
        guard let configuration = try? VMConfiguration.load(fromBundle: sourceLayout.bundleURL) else {
            throw VMSnapshotError.snapshotMissingConfiguration
        }
        let relativePaths = Self.capturedRelativePaths(
            for: configuration, layout: sourceLayout)
        for relativePath in relativePaths {
            let source = sourceLayout.bundleURL.appendingPathComponent(relativePath)
            guard manager.fileExists(atPath: source.path(percentEncoded: false)) else {
                throw VMSnapshotError.snapshotMissingFile(relativePath)
            }
        }
        return VMSnapshotRestorePlan(
            configuration: configuration, relativePaths: relativePaths, kind: kind)
    }

    /// Clones the snapshot's files into the staging directory.
    ///
    /// Nothing in the bundle is touched, so a failure here — or anything that
    /// stops the revert before ``installRestore(bundleURL:plan:)`` — leaves the
    /// bundle exactly as it was. A cold plan stages no saved state.
    func stageRestore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let sourceLayout = layout.snapshotLayout(id: snapshotID)
        let stagingLayout = VMBundleLayout(bundleURL: layout.restoreStagingURL)
        let manager = FileManager.default
        let staging = stagingLayout.bundleURL

        // A staging directory left behind by an interrupted revert holds clones
        // that may be truncated, so it is discarded rather than resumed.
        try? manager.removeItem(at: staging)
        do {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            // Same volume, so APFS clones each file rather than duplicating its
            // blocks — the staged copy shares them with the snapshot's own.
            for relativePath in plan.relativePaths {
                let source = sourceLayout.bundleURL.appendingPathComponent(relativePath)
                let staged = staging.appendingPathComponent(relativePath)
                try manager.createDirectory(
                    at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: staged)
            }
            if plan.kind == .warm {
                try manager.copyItem(at: sourceLayout.saveFileURL, to: stagingLayout.saveFileURL)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Swaps each staged file into the bundle, then removes the staging
    /// directory.
    ///
    /// Each swap is a rename, so a file the bundle holds is never absent,
    /// whatever interrupts the revert. A cold plan drops the bundle's own saved
    /// state, so the VM comes back stopped on the captured disks.
    func installRestore(bundleURL: URL, plan: VMSnapshotRestorePlan) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let stagingLayout = VMBundleLayout(bundleURL: layout.restoreStagingURL)
        let manager = FileManager.default
        let staging = stagingLayout.bundleURL
        defer { try? manager.removeItem(at: staging) }

        do {
            if plan.kind == .cold {
                // First, and only once staging succeeded: a save file describing
                // pre-revert RAM sitting over post-revert disks is the corruption
                // the catch below exists to undo, so a cold revert never lets that
                // pairing exist. An interruption after this point leaves a stopped
                // VM on its pre-revert disks, which costs nothing.
                try removeSaveFile(bundleURL: bundleURL)
            }
            for relativePath in plan.relativePaths {
                try swapIntoPlace(
                    staged: staging.appendingPathComponent(relativePath),
                    destination: layout.bundleURL.appendingPathComponent(relativePath))
            }
            if plan.kind == .warm {
                // Last, so the VM only reads as suspended-on-the-snapshot once the
                // disks and configuration that state belongs to are already in place.
                try swapIntoPlace(staged: stagingLayout.saveFileURL, destination: layout.saveFileURL)
            }
        } catch {
            // The bundle's own saved state describes the guest RAM that belongs
            // to the disks the swaps above already replaced, and a bundle
            // holding one rests the VM at `.paused` — offering a resume that
            // would run pre-revert RAM on post-revert disks. Dropping it rests
            // the VM at `.stopped` instead.
            try? manager.removeItem(at: layout.saveFileURL)
            throw error
        }
    }

    /// Moves a staged clone onto `destination`, replacing whatever is there.
    ///
    /// `replaceItemAt` rather than a remove followed by a copy: it renames the
    /// replacement in, so `destination` resolves to the old file or the new one
    /// and never to nothing.
    private func swapIntoPlace(staged: URL, destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            // `replaceItemAt` needs an original to replace — a disk the VM lost
            // since the capture has none.
            try manager.moveItem(at: staged, to: destination)
        }
    }

    func sweepRestoreStaging(bundleURL: URL) {
        let staging = VMBundleLayout(bundleURL: bundleURL).restoreStagingURL
        let manager = FileManager.default
        guard manager.fileExists(atPath: staging.path(percentEncoded: false)) else { return }
        do {
            try manager.removeItem(at: staging)
            #log(
                Self.logger, .notice,
                "Reclaimed a revert staging directory left in '\(bundleURL.lastPathComponent, privacy: .public)'"
            )
        } catch {
            #log(
                Self.logger, .warning,
                "Failed to remove the revert staging directory in '\(bundleURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Removal

    func discardSnapshot(bundleURL: URL, snapshotID: UUID) throws {
        let directory = VMBundleLayout(bundleURL: bundleURL).snapshotDirectoryURL(id: snapshotID)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return
        }
        try fileSystem.trashItem(at: directory)
    }

    func removeSnapshotDirectory(bundleURL: URL, snapshotID: UUID) {
        let directory = VMBundleLayout(bundleURL: bundleURL).snapshotDirectoryURL(id: snapshotID)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // Nothing was written before the failure.
        } catch {
            #log(
                Self.logger, .warning,
                "Failed to clean up the partial snapshot directory '\(snapshotID.uuidString, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Suspend slot

    func removeSaveFile(bundleURL: URL) throws {
        do {
            try FileManager.default.removeItem(at: VMBundleLayout(bundleURL: bundleURL).saveFileURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // A stopped VM holds no suspend slot, which is the common case.
        }
    }

    // MARK: - Firmware and platform

    func ensureEFIVariableStore(bundleURL: URL) throws {
        let url = VMBundleLayout(bundleURL: bundleURL).efiVariableStoreURL
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        _ = try VZEFIVariableStore(creatingVariableStoreAt: url, options: [])
        #log(
            Self.logger, .notice,
            "Created the EFI variable store in '\(bundleURL.lastPathComponent, privacy: .public)'")
    }

    func createMacPlatformFiles(bundleURL: URL, hardwareModel: Data) throws -> Data {
        guard let model = VZMacHardwareModel(dataRepresentation: hardwareModel) else {
            throw ConfigurationBuilderError.invalidHardwareModel
        }
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let manager = FileManager.default
        if !manager.fileExists(atPath: layout.hardwareModelURL.path(percentEncoded: false)) {
            try hardwareModel.write(to: layout.hardwareModelURL)
        }
        if !manager.fileExists(atPath: layout.machineIdentifierURL.path(percentEncoded: false)) {
            try VZMacMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifierURL)
        }
        // Without `.allowOverwrite`, a second Start after an install that got past
        // setup but didn't finish throws "File exists" before the installer runs.
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: layout.auxiliaryStorageURL, hardwareModel: model,
            options: [.allowOverwrite])
        #log(
            Self.logger, .info,
            "Created platform files in '\(bundleURL.lastPathComponent, privacy: .public)'")
        return try Data(contentsOf: layout.machineIdentifierURL)
    }

    // MARK: - In-bundle disks

    func createInternalDisk(
        bundleURL: URL, id: UUID, sizeInGB: Int, diskImages: any DiskImageProviding
    ) async throws -> String {
        let relativePath = VMBundleLayout.additionalDiskRelativePath(id: id)
        let url = bundleURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await diskImages.createDiskImage(at: url, sizeInGB: sizeInGB)
        } catch {
            // Only when the write itself failed — the earlier phases throw
            // before the destination file is touched. The path is minted per
            // create and no configuration names it yet, so what the write left
            // is app-internal.
            if case DiskImageError.writeFailed = error {
                do {
                    try fileSystem.removeItem(at: url)
                } catch {
                    #log(
                        Self.logger, .warning,
                        "Failed to clean up partial disk image at '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
        return relativePath
    }

    func trashInternalDisk(bundleURL: URL, relativePath: String) throws {
        try fileSystem.trashItem(at: bundleURL.appendingPathComponent(relativePath))
    }

    // MARK: - Sizes

    func onDiskBytes(bundleURL: URL, snapshotIDs: [UUID]) -> [UUID: UInt64] {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        var sizes: [UUID: UInt64] = [:]
        for id in snapshotIDs {
            sizes[id] = Self.allocatedBytes(of: layout.snapshotDirectoryURL(id: id))
        }
        return sizes
    }

    /// Blocks allocated to everything under `directory`.
    ///
    /// A block a copy-on-write clone shares with the file it was cloned from is
    /// counted in full, for the clone and for the original alike — the figure is
    /// what the snapshot's files occupy, not what deleting the snapshot frees.
    private static func allocatedBytes(of directory: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])
        else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let allocated = values?.totalFileAllocatedSize
            else { continue }
            total &+= UInt64(allocated)
        }
        return total
    }
}

// MARK: - Errors

enum VMSnapshotError: LocalizedError {
    /// A file the snapshot should capture is not in the bundle.
    case captureSourceMissing(String)
    /// The snapshot holds no saved state to restore from.
    case snapshotMissingSavedState
    /// The snapshot holds no record of the configuration it was captured under,
    /// which VZ requires back before it restores the saved state.
    case snapshotMissingConfiguration
    /// The snapshot holds no copy of a file its own configuration names.
    case snapshotMissingFile(String)

    var errorDescription: String? {
        switch self {
        case .captureSourceMissing(let path):
            "The snapshot could not be taken: \u{201C}\(path)\u{201D} is missing from the virtual machine's bundle."
        case .snapshotMissingSavedState:
            "This snapshot has no saved state, so it can't be reverted to."
        case .snapshotMissingConfiguration:
            "This snapshot has no record of the virtual machine's settings, so it can't be reverted to."
        case .snapshotMissingFile(let path):
            "This snapshot doesn't include \u{201C}\(path)\u{201D}, so it can't be reverted to."
        }
    }
}
