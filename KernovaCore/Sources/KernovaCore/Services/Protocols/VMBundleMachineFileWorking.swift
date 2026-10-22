import Foundation
import KernovaKit

/// Where a prepared snapshot's saved state belongs, and the bundle-relative
/// files copied beside it.
///
/// `saveFileURL` goes unused by a cold capture, which writes no saved state.
package struct VMSnapshotCapturePlan: Sendable {
    package let saveFileURL: URL
    package let relativePaths: [String]

    package init(saveFileURL: URL, relativePaths: [String]) {
        self.saveFileURL = saveFileURL
        self.relativePaths = relativePaths
    }
}

/// What one snapshot holds, checked complete: the configuration it was captured
/// under and the bundle-relative files it copied.
package struct VMSnapshotRestorePlan: Sendable {
    /// The configuration the saved state was written under.
    ///
    /// A revert commits this over the VM's current one, keeping the VM's
    /// identity (``VMConfiguration/adoptingSnapshotState(_:)``).
    let configuration: VMConfiguration

    /// The files to write back, derived from ``configuration`` rather than the
    /// VM's current one — a disk the VM gained or lost since the capture is
    /// neither restored nor able to block the revert.
    package let relativePaths: [String]

    /// What the snapshot captured, which decides whether the revert installs a
    /// saved state or drops the bundle's.
    package let kind: VMSnapshotKind

    package init(configuration: VMConfiguration, relativePaths: [String], kind: VMSnapshotKind) {
        self.configuration = configuration
        self.relativePaths = relativePaths
        self.kind = kind
    }
}

/// The file work behind ``VMBundle``'s machine files, which a
/// ``VMBundle/Factory`` holds for the bundles it builds.
///
/// Every method blocks on the filesystem, so ``VMBundle`` calls them off the
/// main actor.
package protocol VMBundleMachineFileWorking: VMPlatformFileWriting {
    // MARK: Snapshots

    /// Creates the snapshot's directory and writes the configuration the
    /// capture is taken under, ready for a saved state to be written beside it.
    func prepareSnapshot(
        bundleURL: URL, snapshotID: UUID, configuration: VMConfiguration
    ) throws -> VMSnapshotCapturePlan

    /// Copies `relativePaths` from the bundle into the snapshot's directory.
    ///
    /// Same-volume copies, which APFS makes copy-on-write.
    func captureDisks(bundleURL: URL, snapshotID: UUID, relativePaths: [String]) throws

    /// Clones the bundle's suspend slot into the snapshot's own saved state.
    ///
    /// Same-volume copy, which APFS makes copy-on-write — the slot the VM
    /// would resume from is left in place.
    func captureSuspendSlot(bundleURL: URL, snapshotID: UUID) throws

    /// Reads what the snapshot holds and checks every captured file is present;
    /// only a `.warm` snapshot is required to hold a saved state.
    ///
    /// Touches nothing in the bundle, so a revert runs it while the VM is still
    /// live and refuses without having cost the user anything.
    func planRestore(
        bundleURL: URL, snapshotID: UUID, kind: VMSnapshotKind
    ) throws -> VMSnapshotRestorePlan

    /// Clones the snapshot's captured disks — and, for a warm plan, its saved
    /// state — into the bundle's restore staging directory, touching nothing
    /// in the bundle itself.
    ///
    /// A failure removes whatever it staged.
    func stageRestore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws

    /// Swaps the files ``stageRestore(bundleURL:snapshotID:plan:)`` staged into
    /// the bundle, replacing whatever is there — installing the snapshot's
    /// saved state for a warm plan, dropping the bundle's for a cold one — and
    /// removes the staging directory.
    ///
    /// A failure during the swaps leaves the bundle with no saved state at
    /// all, since the one it held belongs to the disks already replaced.
    func installRestore(bundleURL: URL, plan: VMSnapshotRestorePlan) throws

    /// Removes the bundle's restore staging directory: the one an interrupted
    /// revert left, or the one a revert that stopped before its install
    /// staged.
    ///
    /// Clones left there stop sharing blocks the moment the snapshot they came
    /// from is discarded, and no snapshot the library lists accounts for them.
    func sweepRestoreStaging(bundleURL: URL)

    /// Moves one snapshot's directory to the Trash.
    func discardSnapshot(bundleURL: URL, snapshotID: UUID) throws

    /// Removes a snapshot's directory outright, for cleaning up a capture that
    /// failed partway.
    func removeSnapshotDirectory(bundleURL: URL, snapshotID: UUID)

    /// The size of each snapshot, keyed by snapshot id; a snapshot
    /// whose size can't be read has no entry.
    func snapshotSizes(bundleURL: URL, snapshotIDs: [UUID]) -> [UUID: SnapshotSize]

    /// The footprint and capacity of each image in `images`, keyed as given;
    /// every key has an entry, whose figures are `nil` where its file can't be
    /// read.
    func diskSizes(
        bundleURL: URL, images: [UUID: DiskImageReference]
    ) -> [UUID: VMBundleLayout.DiskSizes]

    // MARK: Suspend slot

    /// Removes the bundle's suspend slot; a bundle holding none is a success.
    func removeSaveFile(bundleURL: URL) throws

    /// Moves the bundle's suspend slot to the spent path, replacing any file
    /// already there, and answers `true`; answers `false`, touching nothing,
    /// when no slot is at `bundleURL`. A move the file system refuses throws
    /// and leaves the slot in place.
    func spendSaveFile(bundleURL: URL) throws -> Bool

    /// Moves the spent suspend slot back to the slot path.
    func reinstateSpentSaveFile(bundleURL: URL) throws

    /// Removes the spent suspend slot; a bundle holding none is a success.
    func removeSpentSaveFile(bundleURL: URL) throws

    // MARK: In-bundle disks

    /// Writes a new disk image of `sizeInGB` at the in-bundle path `id` names,
    /// answering that path relative to the bundle.
    ///
    /// A write that fails removes whatever it left there.
    func createInternalDisk(
        bundleURL: URL, id: UUID, sizeInGB: Int, diskImages: any DiskImageProviding
    ) async throws -> String

    /// Moves the in-bundle disk at `relativePath` to the Trash.
    func trashInternalDisk(bundleURL: URL, relativePath: String) throws
}

// MARK: - Errors

package enum VMSnapshotError: LocalizedError, TitledError {
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

    package var errorDescription: String? {
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

/// The firmware and platform files of a VM bundle, which only Virtualization
/// writes; the engine answers it, and ``VMBundleMachineFiles`` hands its
/// requirements to one.
package protocol VMPlatformFileWriting: Sendable {
    /// Creates the bundle's EFI variable store unless it already holds one.
    func ensureEFIVariableStore(bundleURL: URL) throws

    /// Writes the macOS platform files an install boots from, answering the
    /// machine identifier the bundle now holds.
    ///
    /// `HardwareModel` and `MachineIdentifier` are written only when absent, so
    /// the guest keeps one identity across install retries; `AuxiliaryStorage`
    /// is always created afresh for `hardwareModel`, since it carries the
    /// firmware state a fresh install run must match.
    func createMacPlatformFiles(bundleURL: URL, hardwareModel: Data) throws -> Data
}
