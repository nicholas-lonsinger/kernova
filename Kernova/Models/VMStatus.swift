import Foundation

/// The runtime status of a virtual machine.
enum VMStatus: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case paused
    case saving
    case restoring
    case installing
    /// VM exists in the library but has never completed its initial boot
    /// (macOS install pipeline hasn't run). Clicking Start kicks off the
    /// install (which may resume an interrupted download), then auto-boots.
    case initialBoot
    case error

    var displayName: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .paused: "Paused"
        case .saving: "Suspending"
        case .restoring: "Restoring"
        case .installing: "Installing"
        case .initialBoot: "Initial Boot"
        case .error: "Error"
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .saving, .restoring, .installing: true
        default: false
        }
    }

    /// Overlay label for save/restore transitions, or `nil` for all other states
    /// (including `.starting` and `.installing`, which use a generic progress view instead).
    var transitionLabel: String? {
        switch self {
        case .saving: "Suspending…"
        case .restoring: "Restoring…"
        default: nil
        }
    }

    var canStart: Bool { self == .stopped || self == .error || self == .initialBoot }
    /// Status-level stop eligibility.
    ///
    /// Does not account for cold-paused state;
    /// prefer `VMInstance.canStop` for runtime checks.
    var canStop: Bool { self == .running || self == .paused }
    var canPause: Bool { self == .running }
    var canResume: Bool { self == .paused }
    /// Status-level save eligibility.
    ///
    /// Does not account for cold-paused state;
    /// prefer `VMInstance.canSave` for runtime checks.
    var canSave: Bool { self == .running || self == .paused }
    var canEditSettings: Bool { self == .stopped || self == .error || self == .initialBoot }
    var canRename: Bool { !isTransitioning }

    /// Whether the VM has a live display session that a backing view should present.
    var hasActiveDisplay: Bool {
        switch self {
        case .running, .paused, .saving, .restoring: true
        default: false
        }
    }

    var canForceStop: Bool {
        switch self {
        case .running, .paused, .starting, .saving, .restoring: true
        default: false
        }
    }

    /// Whether this status represents an active VM that should keep the app alive.
    ///
    /// Note: live-paused VMs (`.paused` with a non-nil `VZVirtualMachine`) should
    /// be handled separately by the caller.
    var isActive: Bool {
        switch self {
        case .running, .starting, .saving, .restoring, .installing:
            true
        case .paused, .stopped, .error, .initialBoot:
            false
        }
    }
}
