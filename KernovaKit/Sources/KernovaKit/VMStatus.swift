import Foundation

/// The vocabulary a VM's runtime state is named in — the projection every
/// automation surface and every label reads off `VMLifecyclePhase`.
///
/// The raw value is the name every automation surface reads and writes;
/// ``displayName`` is what a person reads. Nothing is *decided* here: a
/// predicate belongs to the phase, which distinguishes the cases a status
/// deliberately conflates.
public enum VMStatus: String, Sendable {
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

    /// The wire name a VM whose bundle is still being written by a create,
    /// clone or import reports.
    ///
    /// Deliberately not a case: it is not a runtime state a session can be in,
    /// and nothing but a listing ever sees it.
    public static let preparingWireName = "preparing"

    /// What a person reads for this status.
    public var displayName: String {
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

    /// A status read off the wire, in the words a person reads.
    ///
    /// Answers for ``preparingWireName``, which is no case of this type, and
    /// falls back to the raw name for anything else — which only a peer from
    /// another vocabulary could send.
    public static func displayName(forWireName wireName: String) -> String {
        if let known = VMStatus(rawValue: wireName) { return known.displayName }
        return wireName == preparingWireName ? "Preparing" : wireName
    }
}
