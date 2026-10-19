import Foundation
import KernovaKit
import KernovaLogging

/// The file operations behind ``VMBundle``'s machine files, against the real
/// filesystem. A snapshot's directory holds its VZ saved state, the
/// configuration it was captured under and copy-on-write disk copies.
///
/// `VMBundleLayout` owns the names; this owns the file operations, and
/// `platform` writes the firmware and platform files.
package struct VMBundleMachineFiles: VMBundleMachineFileWorking {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMBundleMachineFiles")

    /// The operations a test must not run for real: trashing moves a file into
    /// the user's own Trash. Every other file operation here runs against real
    /// files, which is what this type's tests exercise.
    private let fileSystem: any FileSystemOperating

    private let platform: any VMPlatformFileWriting

    package init(fileSystem: any FileSystemOperating, platform: any VMPlatformFileWriting) {
        self.fileSystem = fileSystem
        self.platform = platform
    }

    // MARK: - Capture

    package func prepareSnapshot(
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
            relativePaths: VMBundleItems.capturedRelativePaths(for: configuration, layout: layout))
    }

    package func captureDisks(bundleURL: URL, snapshotID: UUID, relativePaths: [String]) throws {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        try VMBundleItems.copyItems(
            relativePaths, from: layout.bundleURL,
            to: layout.snapshotDirectoryURL(id: snapshotID),
            ifMissing: .fail { VMSnapshotError.captureSourceMissing($0) })
    }

    package func captureSuspendSlot(bundleURL: URL, snapshotID: UUID) throws {
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
    package func planRestore(
        bundleURL: URL, snapshotID: UUID, kind: VMSnapshotKind
    ) throws -> VMSnapshotRestorePlan {
        let sourceLayout = VMBundleLayout(bundleURL: bundleURL).snapshotLayout(id: snapshotID)
        let manager = FileManager.default

        if kind == .warm,
            !manager.fileExists(atPath: sourceLayout.saveFileURL.path(percentEncoded: false))
        {
            throw VMSnapshotError.snapshotMissingSavedState
        }
        let configuration: VMConfiguration
        do {
            configuration = try VMConfiguration.load(fromBundle: sourceLayout.bundleURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw VMSnapshotError.snapshotMissingConfiguration
        } catch {
            throw VMSnapshotError.snapshotConfigurationUnreadable
        }
        let relativePaths = VMBundleItems.capturedRelativePaths(
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
    package func stageRestore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws {
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
            try VMBundleItems.copyItems(
                plan.relativePaths, from: sourceLayout.bundleURL, to: staging,
                ifMissing: .unchecked)
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
    package func installRestore(bundleURL: URL, plan: VMSnapshotRestorePlan) throws {
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
            // holding one rests the VM at `.suspended` — offering a resume that
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

    package func sweepRestoreStaging(bundleURL: URL) {
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

    package func discardSnapshot(bundleURL: URL, snapshotID: UUID) throws {
        let directory = VMBundleLayout(bundleURL: bundleURL).snapshotDirectoryURL(id: snapshotID)
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return
        }
        try fileSystem.trashItem(at: directory)
    }

    package func removeSnapshotDirectory(bundleURL: URL, snapshotID: UUID) {
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

    package func removeSaveFile(bundleURL: URL) throws {
        do {
            try FileManager.default.removeItem(at: VMBundleLayout(bundleURL: bundleURL).saveFileURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        {
            // A stopped VM holds no suspend slot, which is the common case.
        }
    }

    // MARK: - Firmware and platform

    package func ensureEFIVariableStore(bundleURL: URL) throws {
        try platform.ensureEFIVariableStore(bundleURL: bundleURL)
    }

    package func createMacPlatformFiles(bundleURL: URL, hardwareModel: Data) throws -> Data {
        try platform.createMacPlatformFiles(bundleURL: bundleURL, hardwareModel: hardwareModel)
    }

    // MARK: - In-bundle disks

    package func createInternalDisk(
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

    package func trashInternalDisk(bundleURL: URL, relativePath: String) throws {
        try fileSystem.trashItem(at: bundleURL.appendingPathComponent(relativePath))
    }

    // MARK: - Sizes

    package func snapshotSizes(bundleURL: URL, snapshotIDs: [UUID]) -> [UUID: SnapshotSize] {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        var sizes: [UUID: SnapshotSize] = [:]
        for id in snapshotIDs {
            sizes[id] = SnapshotSize.measure(directory: layout.snapshotDirectoryURL(id: id))
        }
        return sizes
    }

    package func diskSizes(
        bundleURL: URL, images: [UUID: DiskImageReference]
    ) -> [UUID: VMBundleLayout.DiskSizes] {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        return images.mapValues(layout.diskSizes(of:))
    }
}
