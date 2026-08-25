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

    func restore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let sourceLayout = layout.snapshotLayout(id: snapshotID)

        // The captured copies are written into place one by one, so a failure
        // partway leaves a mix. Every write is a fresh clone of a file the
        // snapshot still holds, so re-running the revert repairs it.
        for relativePath in plan.relativePaths {
            let source = sourceLayout.bundleURL.appendingPathComponent(relativePath)
            let destination = layout.bundleURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replaceItem(at: destination, withCopyOf: source)
        }
        let data = try VMConfiguration.makeJSONEncoder().encode(plan.configuration)
        try data.write(to: layout.configURL, options: .atomic)
        // Last, so the VM only reads as suspended-on-the-snapshot once the disks
        // and configuration that state belongs to are already in place.
        try replaceItem(at: layout.saveFileURL, withCopyOf: sourceLayout.saveFileURL)
    }

    /// Clones `source` over `destination`, removing whatever was there.
    ///
    /// Not `replaceItemAt`, which moves the replacement in — the snapshot keeps
    /// its copy, so a revert must leave the source where it is.
    private func replaceItem(at destination: URL, withCopyOf source: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
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
