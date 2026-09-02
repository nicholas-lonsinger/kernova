import Foundation
import KernovaKit

/// Every VM verb Kernova offers, typed end to end.
///
/// One method per verb, addressing VMs by ``VMSelector`` and refusing with
/// ``CommandError``. Every front door reaches VMs through this and nothing
/// else — the AppKit UI in process, a wire client through
/// ``VMCommandEnvelopeRouter`` — so each inherits identical addressing, state
/// gates, and consent semantics.
///
/// Consent is a parameter, never a presentation: a destructive verb called
/// without it refuses with ``CommandError/confirmationRequired(_:)`` describing
/// what confirming entails. Implementations present nothing.
///
/// `@MainActor` is a decision, not an accident: library state is UI-adjacent,
/// all VZ work already runs on per-VM `VMSession` actors, and command traffic is
/// human-scale. The `await` at each call site makes the isolation an
/// implementation detail — if it is ever revisited, only the implementation
/// moves.
///
/// A verb that completes synchronously is spelled synchronously. Reserving an
/// import destination is the case that matters: a batch's reservations have to
/// see each other's phantom rows, which one suspension point between them would
/// break.
@MainActor
protocol VMCommanding: AnyObject {
    // MARK: - Reads

    /// Every VM in the library, in the order the sidebar shows them.
    func list() -> [VMSummary]

    func info(_ selector: VMSelector) throws -> VMInfo

    /// The address the app reserved for this guest, `nil` when it has none.
    func ipAddress(of selector: VMSelector) throws -> String?

    /// The VM's named restore points, newest first.
    func snapshots(of selector: VMSelector) throws -> [SnapshotSummary]

    // MARK: - Lifecycle

    /// Starts the VM, running whatever guest setup it still owes first.
    ///
    /// `recovery` cold-boots a stopped macOS guest into macOS Recovery.
    func start(_ selector: VMSelector, recovery: Bool) async throws

    /// Cancels the guest setup a first start is running — a macOS install, or a
    /// Linux installer image being fetched or verified.
    ///
    /// The bundle is preserved and the VM returns to `.initialBoot`, so a later
    /// start resumes it. A VM with no setup in flight refuses.
    func cancelGuestSetup(_ selector: VMSelector, confirmed: Bool) throws

    /// Stops the VM the way `disposition` names.
    ///
    /// A live-paused guest cannot receive an ACPI shutdown, so `.graceful`
    /// there refuses for confirmation and offers the two dispositions that can.
    /// `.force` always asks: it discards unsaved guest state.
    func stop(_ selector: VMSelector, disposition: StopDisposition, confirmed: Bool) async throws

    func pause(_ selector: VMSelector) async throws

    func resume(_ selector: VMSelector) async throws

    /// Save-suspends the VM to its bundle's suspend slot.
    func suspend(_ selector: VMSelector) async throws

    /// Shuts the guest down and starts it again once it has powered off.
    func restart(_ selector: VMSelector) async throws

    /// Brings the VM's display to the front — the detached window for a
    /// pop-out or fullscreen VM, else keyboard focus in the inline display.
    func open(_ selector: VMSelector) throws

    // MARK: - Snapshots

    @discardableResult
    func takeSnapshot(_ selector: VMSelector, name: String, notes: String) async throws
        -> SnapshotSummary

    /// Returns the VM to a snapshot, optionally capturing the current state
    /// first so the revert is reversible.
    func revertToSnapshot(
        _ selector: VMSelector, snapshot: UUID, takingCheckpoint: Bool, confirmed: Bool
    ) async throws

    func deleteSnapshot(_ selector: VMSelector, snapshot: UUID, confirmed: Bool) async throws

    func renameSnapshot(_ selector: VMSelector, snapshot: UUID, to newName: String) throws

    func setSnapshotNotes(_ selector: VMSelector, snapshot: UUID, notes: String) throws

    // MARK: - Library

    /// Writes a new VM's bundle and disk image, answering the row the write
    /// fills.
    ///
    /// `startAfterCreate` boots the VM once its bundle is on disk; a failed
    /// write starts nothing.
    @discardableResult
    func create(configuration: VMConfiguration, startAfterCreate: Bool) throws -> VMSummary

    /// Copies the VM's bundle into a new one, answering the row the copy fills.
    @discardableResult
    func clone(_ selector: VMSelector, machineIdentity: CloneMachineIdentity) throws -> VMSummary

    func rename(_ selector: VMSelector, to newName: String) throws

    /// Deletes the VM's bundle and the external files named in `alsoRemoving`.
    ///
    /// `permanently` bypasses the Trash. Files shared with another VM are never
    /// deleted even when their id is passed.
    func delete(
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, confirmed: Bool
    ) async throws

    /// Copies a `.kernova` bundle into the library, answering the row the copy
    /// fills — or the existing row when the bundle is already in the library.
    @discardableResult
    func importVM(from url: URL) throws -> VMSummary

    /// Cancels an in-flight create, clone or import and removes its row.
    func cancelPreparing(_ selector: VMSelector, confirmed: Bool) throws

    // MARK: - Storage Disks

    /// Appends the picked files to the VM's storage-disk list, skipping paths
    /// it already carries.
    ///
    /// Takes files rather than opening a panel: a pick carries a
    /// security-scoped bookmark only an in-process open panel can mint, which
    /// is why no wire verb offers this.
    func attachStorageDisks(_ selector: VMSelector, paths files: [PickedFile]) throws

    /// Writes a new sparse image inside the VM's bundle and appends it.
    func createStorageDisk(_ selector: VMSelector, sizeInGB: Int) async throws

    /// Drops a storage disk's entry, and with `trashFile` the file behind it.
    ///
    /// A file another VM still references is never trashed, however `trashFile`
    /// is set. A VM's only storage disk is refused, whichever file backs it: a
    /// VM keeps at least one. Any disk with a sibling goes, `Disk.asif` included.
    func removeStorageDisk(
        _ selector: VMSelector, disk: UUID, trashFile: Bool, confirmed: Bool
    ) async throws

    /// Replaces a storage disk's user-facing label; an empty label is a no-op.
    func renameStorageDisk(_ selector: VMSelector, disk: UUID, to newLabel: String) throws

    /// Replaces a storage disk's note. An empty note is a legitimate value —
    /// it clears the note.
    func setStorageDiskNotes(_ selector: VMSelector, disk: UUID, notes: String) throws

    func setStorageDiskReadOnly(_ selector: VMSelector, disk: UUID, readOnly: Bool) throws

    /// Rewrites the boot order; disks `order` does not name keep their relative
    /// order behind those it does.
    func reorderStorageDisks(_ selector: VMSelector, order: [UUID]) throws

    // MARK: - Removable Media

    /// Appends the picked files to the VM's removable-media list, skipping
    /// paths it already carries — off the wire for the reason
    /// ``attachStorageDisks(_:paths:)`` states.
    func attachRemovableMedia(_ selector: VMSelector, paths files: [PickedFile]) throws

    /// Writes a new sparse image at a destination the user chose and attaches
    /// it as a hot-pluggable removable disk.
    ///
    /// Off the wire: the write rides a live save-panel grant, which is also
    /// what the entry's bookmark is minted from.
    func createRemovableMedia(
        _ selector: VMSelector, sizeInGB: Int, destinationURL: URL
    ) async throws

    /// Drops a removable medium's entry, and with `trashFile` the file behind
    /// it.
    ///
    /// The bundled Guest Agent installer and files shared with another VM are
    /// never trashed.
    func removeRemovableMedia(
        _ selector: VMSelector, item: UUID, trashFile: Bool, confirmed: Bool
    ) async throws

    /// Detaches a removable medium and keeps its file — what a running guest
    /// sees as an eject.
    func ejectRemovableMedia(_ selector: VMSelector, item: UUID) throws

    /// Replaces a removable medium's label; an empty label is a no-op.
    func renameRemovableMedia(_ selector: VMSelector, item: UUID, to newLabel: String) throws

    /// Replaces a removable medium's note. An empty note clears it.
    func setRemovableMediaNotes(_ selector: VMSelector, item: UUID, notes: String) throws

    func setRemovableMediaReadOnly(_ selector: VMSelector, item: UUID, readOnly: Bool) throws

    // MARK: - Guest Agent Disk

    /// Puts the bundled guest-agent installer image in front of the guest,
    /// answering which bus it reached the guest on.
    ///
    /// A guest that already carries the image attaches nothing and says so.
    @discardableResult
    func mountGuestAgentDisk(_ selector: VMSelector) throws -> GuestAgentDiskMountOutcome

    /// Takes the bundled installer image away again.
    func unmountGuestAgentDisk(_ selector: VMSelector) throws

    // MARK: - Observation

    /// A stream of library changes, for callers that cannot observe the model.
    ///
    /// Each call returns its own stream; ending iteration drops it.
    func events() -> AsyncStream<VMLibraryEvent>
}
