import Foundation
import os

/// Manages the `Snapshots/` directory inside a VM bundle: the manifest, one
/// directory per snapshot holding its VZ saved state, the configuration it was
/// captured under and copy-on-write disk copies, and the sizes those copies
/// occupy.
///
/// `VMBundleLayout` owns the names; this owns the file operations.
struct VMSnapshotStore: VMSnapshotStoring {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMSnapshotStore")

    /// The one operation a test must not run for real: trashing moves the
    /// directory into the user's own Trash. Every other file operation here
    /// runs against real files, which is what this type's tests exercise.
    private let fileSystem: any FileSystemOperating

    init(fileSystem: any FileSystemOperating = FileManager.default) {
        self.fileSystem = fileSystem
    }

    // MARK: - Captured payload

    /// The bundle-relative paths a snapshot captures alongside the saved state.
    ///
    /// Every file the guest writes through that lives in the bundle: the disks
    /// it boots and stores data on, plus the firmware state VZ mutates
    /// (`AuxiliaryStorage` on macOS, `EFIVariableStore` on EFI Linux). The
    /// bundle's identity files (`HardwareModel`, `MachineIdentifier`) are
    /// deliberately absent — they never change, and a revert must not hand the
    /// VM a different identity.
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
        let disks = configuration.storageDisks ?? [ConfigurationBuilder.defaultMainDisk(layout: layout)]
        var paths = disks.filter(\.isInternal).map(\.path)
        for firmware in ["AuxiliaryStorage", "EFIVariableStore"] {
            let url = layout.bundleURL.appendingPathComponent(firmware)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                paths.append(firmware)
            }
        }
        return paths
    }

    // MARK: - Manifest

    func loadManifest(bundleURL: URL) -> VMSnapshotManifest {
        let url = VMBundleLayout(bundleURL: bundleURL).snapshotManifestURL
        guard let data = try? Data(contentsOf: url) else { return VMSnapshotManifest() }
        do {
            return try VMConfiguration.makeJSONDecoder().decode(VMSnapshotManifest.self, from: data)
        } catch {
            Self.logger.error(
                "Failed to read the snapshot manifest in '\(bundleURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return VMSnapshotManifest()
        }
    }

    func saveManifest(_ manifest: VMSnapshotManifest, bundleURL: URL) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        try FileManager.default.createDirectory(
            at: layout.snapshotsDirectoryURL, withIntermediateDirectories: true)
        let data = try VMConfiguration.makeJSONEncoder().encode(manifest)
        try data.write(to: layout.snapshotManifestURL, options: .atomic)
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

    // MARK: - Restore

    /// The files a revert writes back, taken from the configuration the capture
    /// was made under — so they are the disks the snapshot holds rather than the
    /// ones the VM configures now.
    ///
    /// Read-only, and throws on an incomplete snapshot, so a caller can run it
    /// while the VM is still live.
    func planRestore(bundleURL: URL, snapshotID: UUID) throws -> VMSnapshotRestorePlan {
        let sourceLayout = VMBundleLayout(bundleURL: bundleURL).snapshotLayout(id: snapshotID)
        let manager = FileManager.default

        guard manager.fileExists(atPath: sourceLayout.saveFileURL.path(percentEncoded: false)) else {
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
        return VMSnapshotRestorePlan(configuration: configuration, relativePaths: relativePaths)
    }

    /// Clones the snapshot's files into a staging directory, then swaps each one
    /// into the bundle.
    ///
    /// Nothing in the bundle is touched until every file — the saved state and
    /// the configuration included — is staged, so a failure during the copies
    /// leaves the bundle exactly as it was, and each swap is a rename: a file
    /// the bundle holds is never absent, whatever interrupts the revert.
    func restore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let sourceLayout = layout.snapshotLayout(id: snapshotID)
        let stagingLayout = VMBundleLayout(bundleURL: layout.restoreStagingURL)
        let manager = FileManager.default
        let staging = stagingLayout.bundleURL

        // A staging directory left behind by an interrupted revert holds clones
        // that may be truncated, so it is discarded rather than resumed.
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        // Same volume, so APFS clones each file rather than duplicating its
        // blocks — the staged copy shares them with the snapshot's own.
        for relativePath in plan.relativePaths {
            let source = sourceLayout.bundleURL.appendingPathComponent(relativePath)
            let staged = staging.appendingPathComponent(relativePath)
            try manager.createDirectory(
                at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: staged)
        }
        try manager.copyItem(at: sourceLayout.saveFileURL, to: stagingLayout.saveFileURL)
        // Staged rather than written straight into the bundle: it is the one
        // file of the set that needs fresh blocks, so a volume with none left
        // sails through the clones above and fails here — where the failure
        // still costs the bundle nothing.
        let data = try VMConfiguration.makeJSONEncoder().encode(plan.configuration)
        try data.write(to: stagingLayout.configURL, options: .atomic)

        do {
            for relativePath in plan.relativePaths {
                try swapIntoPlace(
                    staged: staging.appendingPathComponent(relativePath),
                    destination: layout.bundleURL.appendingPathComponent(relativePath))
            }
            try swapIntoPlace(staged: stagingLayout.configURL, destination: layout.configURL)
            // Last, so the VM only reads as suspended-on-the-snapshot once the
            // disks and configuration that state belongs to are already in place.
            try swapIntoPlace(staged: stagingLayout.saveFileURL, destination: layout.saveFileURL)
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
            Self.logger.notice(
                "Reclaimed a revert staging directory left in '\(bundleURL.lastPathComponent, privacy: .public)'"
            )
        } catch {
            Self.logger.warning(
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
            Self.logger.warning(
                "Failed to clean up the partial snapshot directory '\(snapshotID.uuidString, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
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
            "The snapshot could not be taken: \u{201C}\(path)\u{201D} is missing from the virtual machine\u{2019}s bundle."
        case .snapshotMissingSavedState:
            "This snapshot has no saved state, so it can\u{2019}t be reverted to."
        case .snapshotMissingConfiguration:
            "This snapshot has no record of the virtual machine\u{2019}s settings, so it can\u{2019}t be reverted to."
        case .snapshotMissingFile(let path):
            "This snapshot doesn\u{2019}t include \u{201C}\(path)\u{201D}, so it can\u{2019}t be reverted to."
        }
    }
}
