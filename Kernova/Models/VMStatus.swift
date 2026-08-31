import Foundation

/// The vocabulary a VM's runtime state is named in — the projection every
/// automation surface and every label reads off ``VMLifecyclePhase``.
///
/// The raw value is the name every automation surface reads and writes;
/// ``displayName`` is what a person reads. Nothing is *decided* here: a
/// predicate belongs to the phase, which distinguishes the cases a status
/// deliberately conflates.
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

    /// Overlay label for save/restore transitions, or `nil` for all other states.
    var transitionLabel: String? {
        switch self {
        case .saving: "Suspending\u{2026}"
        case .snapshotting: "Taking Snapshot\u{2026}"
        case .restoring: "Restoring\u{2026}"
        default: nil
        }
    }
}
