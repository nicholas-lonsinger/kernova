import Foundation

/// How a start reached the guest — the bring-up admission chose, reported so
/// no caller has to predict it.
///
/// A restore consumes the save file, so once the start is over nothing
/// distinguishes the three; the start that took the branch is the only thing
/// that can say which it was.
enum GuestStartRoute: Equatable, Sendable {
    /// Booted the guest from its disks.
    case coldBoot
    /// The cold boot a Recovery start performs, carrying that start's caveat:
    /// only a macOS guest comes up in Recovery.
    case recoveryBoot
    /// Restored the guest from the bundle's suspend slot, continuing the session
    /// saved there.
    case restoredSavedState

    /// The route `kind` takes, or `nil` for a bring-up that starts no guest of
    /// its own — a guest setup, or a revert.
    init?(_ kind: VMBringUpKind) {
        switch kind {
        case .starting(let recovery): self = recovery ? .recoveryBoot : .coldBoot
        case .restoringSavedState: self = .restoredSavedState
        case .settingUp, .reverting: return nil
        }
    }

    /// Whether this route carries the guest's provisioning options, which
    /// ``MacOSGuestProvisioning/macOSStartOptions(bootIntoRecovery:guestOS:provisioning:)``
    /// states only one of the three can.
    var deliversGuestProvisioning: Bool { self == .coldBoot }
}

/// The Virtualization work each lifecycle operation's body runs.
///
/// Every method runs inside the operation ``VMActivity`` admitted, under its
/// context, and answers where the VM rests. Stop and Force Stop are plain VZ
/// calls that ``VMActivity/requestStop(_:)`` and ``VMActivity/forceStop(_:)``
/// make once they have admitted the session action.
@MainActor
protocol VirtualizationProviding: Sendable {
    /// Brings the guest up the way `context`'s kind names — a cold boot, a
    /// Recovery boot, or the restore of the bundle's saved state — answering
    /// how it reached the guest.
    ///
    /// `provisioning` is the macOS account a cold boot creates inside the
    /// guest; the other two routes create none and ignore it.
    func start(
        _ instance: VMInstance, _ context: borrowing VMBringUpContext,
        provisioning: GuestProvisioningCredentials?
    ) async throws -> VMOperationEnding<GuestStartRoute>

    /// Sends the guest the ACPI shutdown request.
    func requestStop(_ instance: VMInstance) async throws

    /// Terminates the guest where it stands.
    func forceStop(_ instance: VMInstance) async throws

    func pause(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void>

    /// Resumes a live-paused guest from memory.
    func resume(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void>

    /// Writes the guest's state to the bundle's suspend slot and ends the
    /// session.
    func save(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void>

    /// Captures `snapshot` in the mode `context`'s kind names — copies of the
    /// bundle's disks, plus the guest's memory from VZ or cloned from the
    /// bundle's suspend slot, unless the VM is stopped — leaving the VM where
    /// it was found.
    ///
    /// Answers `snapshot` carrying the ``VMSnapshot/macAddress`` of the
    /// configuration the capture wrote.
    func takeSnapshot(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        snapshot: VMSnapshotRecord
    ) async throws -> VMOperationEnding<VMSnapshot>

    /// Returns the VM to `snapshot`, discarding whatever session is live and
    /// keeping the snapshot itself.
    ///
    /// The VM lands in the state the snapshot captured: suspended on a warm
    /// snapshot's memory image, stopped on a cold snapshot's disks — and a
    /// revert whose kind `resumesAfter` restores that memory image inside the
    /// same operation, a failure there arriving as
    /// ``VirtualizationError/revertResumeFailed(underlying:)`` with the files
    /// already written. `commitConfiguration` receives the plan once the
    /// snapshot's files are staged and before any of them is swapped into the
    /// bundle; a throw there discards the staging and leaves the bundle as it
    /// was.
    func revertToSnapshot(
        _ instance: VMInstance, _ context: borrowing VMBringUpContext, snapshot: VMSnapshot,
        commitConfiguration: @MainActor (VMSnapshotRestorePlan) throws -> Void
    ) async throws -> VMOperationEnding<Void>
}
