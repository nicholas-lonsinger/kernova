import Foundation

/// The runtime status of a virtual machine.
///
/// The raw value is the name every automation surface reads and writes;
/// ``displayName`` is what a person reads.
enum VMStatus: String, Sendable {
    case stopped
    case starting
    case running
    case paused
    case saving
    /// Capturing a named snapshot: the guest is paused while its state is
    /// written, then put back the way it was found.
    case snapshotting
    case restoring
    case installing
    /// VM exists in the library but has never completed its initial boot.
    /// Clicking Start kicks off the macOS install, then auto-boots.
    case initialBoot
    case error

    var displayName: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .paused: "Paused"
        case .saving: "Suspending"
        case .snapshotting: "Taking Snapshot"
        case .restoring: "Restoring"
        case .installing: "Installing"
        case .initialBoot: "Initial Boot"
        case .error: "Error"
        }
    }

    /// Whether the VM is mid-operation, so terminating would interrupt the work
    /// rather than suspend a settled VM.
    ///
    /// `.running` and `.paused` are excluded deliberately: termination
    /// save-suspends those, which is their intended shutdown path. Exhaustive
    /// rather than `default`, so a new state has to choose a side.
    var isTransitioning: Bool {
        switch self {
        case .starting, .saving, .snapshotting, .restoring, .installing:
            true
        case .running, .paused, .stopped, .error, .initialBoot:
            false
        }
    }

    /// Whether terminating during this state would leave a half-written file
    /// where a complete one belongs, so a quit must wait the operation out
    /// instead of exiting through it.
    ///
    /// The subset of ``isTransitioning`` an *explicit* quit is obliged to honor:
    /// `VZVirtualMachine.saveMachineStateTo` writes the save file in place, so an
    /// exit mid-write truncates the file a later restore reads. A restore keeps
    /// that file until its resume succeeds, and a start or install writes nothing
    /// a relaunch cannot redo. Exhaustive rather than `default`, so a new state
    /// has to choose a side.
    var terminationMustWaitOut: Bool {
        switch self {
        case .saving, .snapshotting:
            true
        case .starting, .restoring, .installing, .running, .paused, .stopped, .error, .initialBoot:
            false
        }
    }

    /// Overlay label for save/restore transitions, or `nil` for all other states.
    var transitionLabel: String? {
        switch self {
        case .saving: "Suspending…"
        case .snapshotting: "Taking Snapshot…"
        case .restoring: "Restoring…"
        default: nil
        }
    }

    var canStart: Bool { self == .stopped || self == .error || self == .initialBoot }
    /// Status-level stop eligibility.
    ///
    /// Does not account for cold-paused state; prefer `VMInstance.canStop`.
    var canStop: Bool { self == .running || self == .paused }
    var canPause: Bool { self == .running }
    var canResume: Bool { self == .paused }
    /// Status-level save eligibility.
    ///
    /// Does not account for cold-paused state; prefer `VMInstance.canSave`.
    var canSave: Bool { self == .running || self == .paused }
    var canEditSettings: Bool { self == .stopped || self == .error || self == .initialBoot }
    var canRename: Bool { !isTransitioning }

    /// Whether a rename committed in this state survives.
    ///
    /// `.restoring` is the one that does not: a revert reads the configuration
    /// it will assign back before it starts writing files
    /// (``VirtualizationService/revertToSnapshot(_:snapshot:store:)``), so a
    /// name written while it runs is overwritten when it lands. Every other
    /// state leaves the configuration alone, so a rename typed into a field
    /// editor that was open when the VM moved is kept rather than refused.
    var renamePersists: Bool { self != .restoring }

    /// Whether the VM has a live display session that a backing view should present.
    var hasActiveDisplay: Bool {
        switch self {
        case .running, .paused, .saving, .snapshotting, .restoring: true
        default: false
        }
    }

    var canForceStop: Bool {
        switch self {
        case .running, .paused, .starting, .saving, .snapshotting, .restoring: true
        default: false
        }
    }

    /// Whether this status represents an active VM that should keep the app alive.
    ///
    /// Live-paused VMs (`.paused` with a live `VZVirtualMachine`) must be
    /// handled separately by the caller.
    var isActive: Bool {
        switch self {
        case .running, .starting, .saving, .snapshotting, .restoring, .installing:
            true
        case .paused, .stopped, .error, .initialBoot:
            false
        }
    }
}
