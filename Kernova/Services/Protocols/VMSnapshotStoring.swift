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
    /// configuration the state was saved from, so a revert installs this over
    /// the VM's current one; the caller carries the VM's identity across first.
    var configuration: VMConfiguration

    /// The files to write back, derived from ``configuration`` rather than the
    /// VM's current one — a disk the VM gained or lost since the capture is
    /// neither restored nor able to block the revert.
    let relativePaths: [String]

    /// What the snapshot captured, which decides whether the revert installs a
    /// saved state or drops the bundle's.
    let kind: VMSnapshotKind
}

/// The `Snapshots/` store inside a VM bundle: its manifest, the captured disk
/// copies, and their on-disk footprints.
///
/// Every method blocks on the filesystem, so callers run them off the main
/// actor.
protocol VMSnapshotStoring: Sendable {
    /// Reads the manifest, answering an empty one for a bundle that holds no
    /// snapshots or whose manifest can't be read.
    func loadManifest(bundleURL: URL) -> VMSnapshotManifest

    func saveManifest(_ manifest: VMSnapshotManifest, bundleURL: URL) throws

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

    /// Writes the snapshot's captured disks and configuration back over the
    /// bundle's own, replacing whatever is there — installing the snapshot's
    /// saved state for a warm plan, dropping the bundle's for a cold one.
    ///
    /// The files are cloned aside first and swapped in only once every clone
    /// exists, so a failure before the swap leaves the bundle untouched. A
    /// failure during the swaps leaves the bundle with no saved state at all,
    /// since the one it held belongs to the disks already replaced.
    func restore(bundleURL: URL, snapshotID: UUID, plan: VMSnapshotRestorePlan) throws

    /// Removes the staging directory an interrupted revert left in the bundle.
    ///
    /// A revert discards its own staging directory, so one found here outlived
    /// the process that made it. Its clones stop sharing blocks the moment the
    /// snapshot they came from is discarded, and no snapshot the library lists
    /// accounts for them.
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
}
