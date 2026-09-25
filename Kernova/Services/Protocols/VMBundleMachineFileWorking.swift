import Foundation

/// Where a prepared snapshot's saved state belongs, and the bundle-relative
/// files copied beside it.
///
/// `saveFileURL` goes unused by a cold capture, which writes no saved state.
struct VMSnapshotCapturePlan: Sendable {
    let saveFileURL: URL
    let relativePaths: [String]
}

/// What one snapshot holds, checked complete: the configuration it was captured
/// under and the bundle-relative files it copied.
struct VMSnapshotRestorePlan: Sendable {
    /// The configuration the saved state was written under.
    ///
    /// `VZVirtualMachine.restoreMachineStateFrom` restores only into the
    /// configuration the state was saved from, so a revert commits this over
    /// the VM's current one, keeping the VM's identity.
    let configuration: VMConfiguration

    /// The files to write back, derived from ``configuration`` rather than the
    /// VM's current one — a disk the VM gained or lost since the capture is
    /// neither restored nor able to block the revert.
    let relativePaths: [String]

    /// What the snapshot captured, which decides whether the revert installs a
    /// saved state or drops the bundle's.
    let kind: VMSnapshotKind
}

/// The file work behind ``VMBundle``'s machine files: the `Snapshots/` store
/// (captured copies, restore staging, footprints), the suspend slot, the
/// firmware and platform files, and the in-bundle disks. The state files are
/// ``VMBundleFiles``'.
///
/// Every method blocks on the filesystem, so ``VMBundle`` calls them off the
/// main actor.
protocol VMBundleMachineFileWorking: Sendable {
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

    /// Bytes each snapshot occupies on disk, keyed by snapshot id.
    ///
    /// The copies share their blocks with the bundle's live disks until either
    /// side changes, so a snapshot's figure counts blocks the VM — and every
    /// other snapshot cloned from the same disk — also counts.
    func onDiskBytes(bundleURL: URL, snapshotIDs: [UUID]) -> [UUID: UInt64]

    // MARK: Suspend slot

    /// Removes the bundle's suspend slot; a bundle holding none is a success.
    func removeSaveFile(bundleURL: URL) throws

    // MARK: Firmware and platform

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
