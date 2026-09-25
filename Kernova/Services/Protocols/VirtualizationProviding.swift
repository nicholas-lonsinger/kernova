import Foundation

/// How a start reached the guest — decided by the VM's state as the start read
/// it, and reported so no caller has to predict it.
///
/// A restore consumes the save file, so once the start is over nothing
/// distinguishes the three; the start that took the branch is the only thing
/// that can say which it was.
enum GuestStartRoute: Equatable, Sendable {
    /// Booted the guest from its disks.
    case coldBoot
    /// The cold boot a `bootIntoRecovery` start performs, carrying the same
    /// caveat that flag does: only a macOS guest comes up in Recovery.
    case recoveryBoot
    /// Restored the guest from the bundle's suspend slot, continuing the session
    /// saved there.
    case restoredSavedState

    /// Which route a start of `instance` takes.
    ///
    /// The one derivation: a start branches *on* this rather than deciding the
    /// same thing twice, so what it answers cannot disagree with what it did.
    @MainActor
    init(startOf instance: VMInstance, bootIntoRecovery: Bool) {
        guard !instance.hasSaveFile else {
            self = .restoredSavedState
            return
        }
        self = bootIntoRecovery ? .recoveryBoot : .coldBoot
    }

    /// Whether this route drops a `bootIntoRecovery` the caller asked for.
    ///
    /// A saved state names the session the guest comes back on, so the restore
    /// performs no cold boot — Recovery included.
    /// ``VMInstance/canStartInRecovery`` refuses a VM holding one, so a request
    /// that still carries the flag came past a gate that should have turned it
    /// back, and the start that reads this says so where it has a logger.
    var dropsRecoveryBoot: Bool { self == .restoredSavedState }

    /// Whether this route carries the guest's provisioning options, which
    /// ``MacOSGuestProvisioning/macOSStartOptions(bootIntoRecovery:guestOS:provisioning:)``
    /// states only one of the three can.
    var deliversGuestProvisioning: Bool { self == .coldBoot }
}

/// Abstraction for VM lifecycle operations (start, stop, pause, resume, save).
///
/// Restore has no entry point of its own — `start` and `resume` restore from a
/// save file when one exists.
@MainActor
protocol VirtualizationProviding: Sendable {
    /// Starts a virtual machine, answering how it reached the guest.
    ///
    /// `bootIntoRecovery` cold-boots a macOS guest into Recovery for this launch
    /// only; it is ignored for Linux guests and for restore-from-save paths.
    ///
    /// `provisioning` is the macOS account this boot creates inside the guest.
    /// Ignored on the same two paths, which create no account.
    ///
    /// Answers the route on every start that reached the guest, the one whose
    /// session was released before it settled included: the guest came up either
    /// way, and that is what the route reports.
    func start(
        _ instance: VMInstance, bootIntoRecovery: Bool,
        provisioning: GuestProvisioningCredentials?
    ) async throws -> GuestStartRoute
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
    ///
    /// Answers `snapshot` carrying the ``VMSnapshot/macAddress`` of the
    /// configuration the capture wrote.
    func takeSnapshot(_ instance: VMInstance, snapshot: VMSnapshotRecord) async throws -> VMSnapshot

    /// Returns the VM to `snapshot`, discarding whatever session is live and
    /// keeping the snapshot itself.
    ///
    /// The VM lands in the state the snapshot captured: paused on a warm
    /// snapshot's memory image, stopped on a cold snapshot's disks — and a VM
    /// that was live when reverted onto a warm snapshot is resumed into it, a
    /// failure there arriving as
    /// ``VirtualizationError/revertResumeFailed(underlying:)`` with the files
    /// already written. `commitConfiguration` receives the plan once the
    /// snapshot's files are staged and before any of them is swapped into the
    /// bundle; a throw there discards the staging and leaves the bundle as it
    /// was.
    func revertToSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot,
        commitConfiguration: @MainActor (VMSnapshotRestorePlan) throws -> Void
    ) async throws
}
