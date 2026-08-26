import Foundation

/// Abstraction for VM lifecycle operations (start, stop, pause, resume, save).
///
/// Restore has no entry point of its own — `start` and `resume` restore from a
/// save file when one exists.
@MainActor
protocol VirtualizationProviding: Sendable {
    /// Starts a virtual machine.
    ///
    /// `bootIntoRecovery` cold-boots a macOS guest into Recovery for this launch
    /// only; it is ignored for Linux guests and for restore-from-save paths.
    func start(_ instance: VMInstance, bootIntoRecovery: Bool) async throws
    func stop(_ instance: VMInstance) async throws
    func forceStop(_ instance: VMInstance) async throws
    func pause(_ instance: VMInstance) async throws
    func resume(_ instance: VMInstance) async throws
    func save(_ instance: VMInstance) async throws

    /// Captures `snapshot`, in the mode the VM is in right now
    /// (``VMInstance/snapshotCaptureMode``) — copies of the bundle's disks,
    /// plus the guest's memory from VZ or cloned from the bundle's suspend
    /// slot, unless the VM is stopped — leaving the VM where it was found.
    /// Throws if the VM has since moved to a mode that disagrees with
    /// `snapshot.kind`.
    func takeSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring
    ) async throws

    /// Returns the VM to `snapshot`, discarding whatever session is live and
    /// keeping the snapshot itself.
    ///
    /// The VM lands in the state the snapshot captured: paused on a warm
    /// snapshot's memory image, stopped on a cold snapshot's disks.
    func revertToSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring
    ) async throws
}
