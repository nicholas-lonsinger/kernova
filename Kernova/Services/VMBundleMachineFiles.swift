import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// The file operations behind ``VMBundle``'s machine files, against the real
/// filesystem. A snapshot's directory holds its VZ saved state, the
/// configuration it was captured under and copy-on-write disk copies.
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
        for firmware in [
            VMBundleLayout.auxiliaryStorageRelativePath, VMBundleLayout.efiVariableStoreRelativePath,
        ] {
            let url = layout.bundleURL.appendingPathComponent(firmware)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                paths.append(firmware)
            }
        }
        return paths
    }

    // MARK: - Copying between bundles

    /// What ``copyItems(_:from:to:ifMissing:)`` does about a path the source
    /// lacks.
    enum MissingItem {
        /// Leaves it out of the copy.
        case skip
        /// Throws what the closure makes of the relative path.
        case fail((String) -> any Error)
        /// Copies without looking first, for a caller that already checked —
        /// the copy's own error reports a path gone since.
        case unchecked
    }

    /// Copies each file or directory `relativePaths` names from the root at
    /// `source` to the same relative path under `destination`, creating the
    /// parent directories it needs.
    static func copyItems(
        _ relativePaths: [String], from source: URL, to destination: URL, ifMissing: MissingItem
    ) throws {
        let manager = FileManager.default
        for relativePath in relativePaths {
            let item = source.appendingPathComponent(relativePath)
            switch ifMissing {
            case .unchecked:
                break
            case .skip, .fail:
                guard !manager.fileExists(atPath: item.path(percentEncoded: false)) else { break }
                if case .fail(let error) = ifMissing { throw error(relativePath) }
                continue
            }
            let copy = destination.appendingPathComponent(relativePath)
            try manager.createDirectory(
                at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Same volume, so APFS clones each file rather than duplicating its
            // blocks — the copy shares them with the original until either
            // side writes.
            try manager.copyItem(at: item, to: copy)
        }
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
        try Self.copyItems(
            relativePaths, from: layout.bundleURL,
            to: layout.snapshotDirectoryURL(id: snapshotID),
            ifMissing: .fail { VMSnapshotError.captureSourceMissing($0) })
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
        let configuration: VMConfiguration
        do {
            configuration = try VMConfiguration.load(fromBundle: sourceLayout.bundleURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw VMSnapshotError.snapshotMissingConfiguration
        } catch {
            throw VMSnapshotError.snapshotConfigurationUnreadable
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
            try Self.copyItems(
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

    func snapshotSizes(bundleURL: URL, snapshotIDs: [UUID]) -> [UUID: SnapshotSize] {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        var sizes: [UUID: SnapshotSize] = [:]
        for id in snapshotIDs {
            sizes[id] = SnapshotSize.measure(directory: layout.snapshotDirectoryURL(id: id))
        }
        return sizes
    }
}

// MARK: - Errors

enum VMSnapshotError: LocalizedError, TitledError {
    /// A file the snapshot should capture is not in the bundle.
    case captureSourceMissing(String)
    /// The snapshot holds no saved state to restore from.
    case snapshotMissingSavedState
    /// The snapshot holds no record of the configuration it was captured under,
    /// which VZ requires back before it restores the saved state.
    case snapshotMissingConfiguration
    /// The snapshot's record of the configuration it was captured under is
    /// there and does not read — the config check lists it.
    case snapshotConfigurationUnreadable
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
        case .snapshotConfigurationUnreadable:
            "Kernova can\u{2019}t read this snapshot\u{2019}s settings. Choose File > Check Config Files\u{2026} to review it."
        case .snapshotMissingFile(let path):
            "This snapshot doesn't include \u{201C}\(path)\u{201D}, so it can't be reverted to."
        }
    }

    var alertTitle: String? {
        switch self {
        case .captureSourceMissing:
            "Couldn\u{2019}t Take the Snapshot"
        case .snapshotMissingSavedState, .snapshotMissingConfiguration,
            .snapshotConfigurationUnreadable, .snapshotMissingFile:
            "Couldn\u{2019}t Revert to the Snapshot"
        }
    }
}
