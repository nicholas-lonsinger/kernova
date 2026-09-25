import Foundation
import KernovaKit

/// Where a VM is in its lifecycle — the one value ``VMInstance`` stores, and
/// what its ``VMStatus``, its failure message and every liveness predicate
/// project from.
///
/// A phase naming a session is installed only while that session is the one the
/// instance holds (``VMInstance/settle(_:for:)``,
/// ``VMInstance/attachSession(from:)``) and released together with it
/// (``VMInstance/tearDownSession(restingAt:)``), so a live phase cannot outlive
/// the `VZVirtualMachine` it describes.
enum VMLifecyclePhase: Sendable, Equatable {
    /// Powered off, with no saved state to come back on.
    case stopped

    /// In the library but never booted — Start runs the guest install first.
    case initialBoot

    /// The last operation failed permanently. `message` is what the error
    /// banner and the status tooltip read, so it cannot survive the move to any
    /// other phase.
    case failed(message: String)

    /// A guest setup is running: a macOS install, or a Linux installer image
    /// being fetched. Sessionless until the installer's VM is created, and for
    /// the whole of a Linux download, which creates none.
    case installing(sessionID: UUID?)

    /// A boot is under way, sessionless until the configuration it is assembled
    /// from produces a `VZVirtualMachine`.
    case starting(sessionID: UUID?)

    case running(sessionID: UUID)

    /// Paused with the `VZVirtualMachine` still in memory, which Resume takes
    /// straight back — as opposed to ``suspended``.
    case livePaused(sessionID: UUID)

    /// Writing the guest's memory into the bundle's suspend slot.
    case saving(sessionID: UUID)

    /// Capturing a snapshot off a live guest: paused for the write, then put
    /// back the way it was found.
    case capturingLive(sessionID: UUID)

    /// Loading a saved state back into a VM, sessionless until that VM exists —
    /// as opposed to ``revertingToSnapshot``, which replaces the bundle's files
    /// with no VM at all.
    case restoringSavedState(sessionID: UUID?)

    /// Suspended to disk: the guest's memory is in the bundle's suspend slot
    /// and nothing is live — the resting phase a save leaves behind.
    case suspended

    /// Copying a stopped or suspended VM's files into a snapshot. A file copy
    /// with no VM behind it.
    case capturingAtRest

    /// Writing a snapshot's files back over the bundle's, with the session the
    /// revert discards already torn down.
    case revertingToSnapshot

    // MARK: - Session Identity

    /// The session this phase names, or `nil` for one that names none.
    ///
    /// The instance's whole liveness answer: a `VZVirtualMachine` is in memory
    /// exactly while this is non-`nil`.
    var sessionID: UUID? {
        switch self {
        case .running(let id), .livePaused(let id), .saving(let id), .capturingLive(let id):
            id
        case .installing(let id), .starting(let id), .restoringSavedState(let id):
            id
        case .stopped, .initialBoot, .failed, .suspended, .capturingAtRest, .revertingToSnapshot:
            nil
        }
    }

    /// This phase with `sessionID` filled in — how a bring-up promotes the
    /// sessionless phase it started under once the `VZVirtualMachine` exists —
    /// or `nil` for a phase that names no session, which is a bring-up that
    /// skipped its in-flight phase.
    ///
    /// Exhaustive rather than `default`, so a new phase has to choose a side.
    func naming(_ sessionID: UUID) -> VMLifecyclePhase? {
        switch self {
        case .starting: .starting(sessionID: sessionID)
        case .installing: .installing(sessionID: sessionID)
        case .restoringSavedState: .restoringSavedState(sessionID: sessionID)
        case .stopped, .initialBoot, .failed, .running, .livePaused, .saving,
            .capturingLive, .suspended, .capturingAtRest, .revertingToSnapshot:
            nil
        }
    }

    // MARK: - Status Projection

    /// The vocabulary every automation surface and every label reads.
    ///
    /// Not injective: the two paused phases and the two capture phases each
    /// report one status, because the distinction is the host's and not the
    /// guest's.
    var status: VMStatus {
        switch self {
        case .stopped: .stopped
        case .initialBoot: .initialBoot
        case .failed: .error
        case .installing: .installing
        case .starting: .starting
        case .running: .running
        case .livePaused, .suspended: .paused
        case .saving: .saving
        case .capturingLive, .capturingAtRest: .snapshotting
        case .restoringSavedState, .revertingToSnapshot: .restoring
        }
    }

    /// The permanent-failure message, or `nil` in every other phase.
    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }

    // MARK: - Transition Predicates

    /// Whether the VM is mid-operation, so terminating would interrupt the work
    /// rather than suspend a settled VM.
    ///
    /// The running and paused phases are excluded: termination save-suspends
    /// those. Exhaustive rather than `default`, so a new phase has to choose
    /// a side.
    var isTransitioning: Bool {
        switch self {
        case .starting, .installing, .saving, .capturingLive, .capturingAtRest,
            .restoringSavedState, .revertingToSnapshot:
            true
        case .running, .livePaused, .suspended, .stopped, .failed, .initialBoot:
            false
        }
    }

    /// Whether terminating during this phase would leave a half-written file
    /// where a complete one belongs, so a quit must wait the operation out
    /// instead of exiting through it.
    ///
    /// The subset of ``isTransitioning`` an *explicit* quit is obliged to honor:
    /// `VZVirtualMachine.saveMachineStateTo` writes the save file in place, so an
    /// exit mid-write truncates the file a later restore reads, and a capture is
    /// copying the bundle's disks. A restore keeps the file it reads until its
    /// resume succeeds, and a start or install writes nothing a relaunch cannot
    /// redo. Exhaustive rather than `default`, so a new phase has to choose a
    /// side.
    var terminationMustWaitOut: Bool {
        switch self {
        case .saving, .capturingLive, .capturingAtRest:
            true
        case .starting, .installing, .restoringSavedState, .revertingToSnapshot, .running,
            .livePaused, .suspended, .stopped, .failed, .initialBoot:
            false
        }
    }

    /// Whether this phase represents an active VM that should keep the app
    /// alive.
    ///
    /// Live-paused VMs are excluded here and handled by the caller: nothing is
    /// executing, but the memory image is only in RAM.
    var isActive: Bool {
        switch self {
        case .running, .starting, .installing, .saving, .capturingLive, .capturingAtRest,
            .restoringSavedState, .revertingToSnapshot:
            true
        case .livePaused, .suspended, .stopped, .failed, .initialBoot:
            false
        }
    }

    // MARK: - Liveness Predicates

    /// Whether a live `VZVirtualMachine` is attached and settled at a state VZ
    /// can act on — the VMs a termination save-suspends, a device can be
    /// attached to, and either kind of stop is offered for.
    ///
    /// ``suspended`` is excluded: its state is already on disk, with nothing
    /// live to act on.
    var hasLiveSession: Bool {
        switch self {
        case .running, .livePaused: true
        default: false
        }
    }

    /// `true` when the VM is paused-to-disk with no `VZVirtualMachine` in
    /// memory.
    var isColdPaused: Bool { self == .suspended }

    /// `true` when the VM is paused with its `VZVirtualMachine` still live —
    /// the resumable counterpart of ``isColdPaused``.
    var isLivePaused: Bool {
        if case .livePaused = self { return true }
        return false
    }

    // MARK: - Command Predicates

    /// Whether the VM is settled with no `VZVirtualMachine` in memory and no
    /// operation in flight — the phases a bring-up begins from, and the ones an
    /// edit, a clone or a delete acts in.
    ///
    /// What the *bundle* holds decides the rest: a VM whose suspend slot is on
    /// disk resumes into it and takes no settings edit
    /// (``VMInstance/holdsSuspendedSession``), whichever of these it rests at.
    /// Exhaustive rather than `default`, so a new phase has to choose a side.
    var isAtRest: Bool {
        switch self {
        case .stopped, .initialBoot, .failed, .suspended:
            true
        case .running, .livePaused, .saving, .capturingLive, .starting, .installing,
            .restoringSavedState, .capturingAtRest, .revertingToSnapshot:
            false
        }
    }

    /// Whether a graceful ACPI shutdown can be asked of the guest.
    var canStop: Bool { hasLiveSession }

    var canPause: Bool {
        if case .running = self { return true }
        return false
    }

    /// Whether the guest's memory can be written to the bundle's suspend slot.
    var canSave: Bool { hasLiveSession }

    var canRename: Bool { !isTransitioning }

    /// Whether a rename committed in this phase survives.
    ///
    /// The restore phases are the ones that do not: a revert reads the
    /// configuration it will assign back before it starts writing files
    /// (``VirtualizationService/revertToSnapshot(_:snapshot:store:)``) and then
    /// chains a save-file restore behind that write, so a name typed while
    /// either runs is overwritten when the revert lands. Every other phase
    /// leaves the configuration alone, so a rename typed into a field editor
    /// that was open when the VM moved is kept rather than refused.
    var renamePersists: Bool {
        switch self {
        case .restoringSavedState, .revertingToSnapshot: false
        default: true
        }
    }

    /// Whether the VM is eligible for forceful termination.
    ///
    /// `VZVirtualMachine.stopWithCompletionHandler:` (macOS 27.0 SDK) "stop[s] a
    /// virtual machine that is in either Running or Paused state", and VZ's own
    /// `Starting`, `Saving` and `Restoring` are none of those: a stop asked
    /// during one is refused with "Invalid virtual machine state transition"
    /// (observed 2026-09-19 against a restore and a suspend, which fail for as
    /// long as VZ is loading or writing). ``hasLiveSession`` names that settled
    /// window, so a force stop is offered only where VZ will take it.
    var canForceStop: Bool { hasLiveSession }

    /// Whether the VM has a display session a backing view should present.
    var hasActiveDisplay: Bool {
        switch self {
        case .running, .livePaused, .suspended, .saving, .capturingLive, .capturingAtRest,
            .restoringSavedState, .revertingToSnapshot:
            true
        case .starting, .installing, .stopped, .failed, .initialBoot:
            false
        }
    }
}

/// A phase a VM leaves rest into to bring a guest up — the only phases
/// ``VMInstance/attachSession(from:)`` promotes to name a session, so the only
/// ones that can put a machine identity and a MAC address in front of VZ.
///
/// Entered only through ``VMInstance/beginBringUp(_:)``, which refuses one
/// another live VM's identity already claims.
enum VMBringUpPhase: Sendable, Equatable {
    case starting
    case restoringSavedState
    case installing

    /// The sessionless lifecycle phase this bring-up stands in until its
    /// `VZVirtualMachine` exists.
    var lifecyclePhase: VMLifecyclePhase {
        switch self {
        case .starting: .starting(sessionID: nil)
        case .restoringSavedState: .restoringSavedState(sessionID: nil)
        case .installing: .installing(sessionID: nil)
        }
    }
}
