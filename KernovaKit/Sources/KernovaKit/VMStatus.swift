import Foundation

/// The vocabulary a VM's runtime state is named in — the projection every
/// automation surface and every label reads off `VMLifecyclePhase`.
///
/// The raw value is the name every automation surface reads and writes;
/// ``displayName`` is what a person reads. Nothing is *decided* here: a
/// predicate belongs to the phase, which distinguishes the cases a status
/// conflates.
public enum VMStatus: String, Sendable {
    case stopped
    case starting
    case running
    /// Paused with its memory held live by this session.
    case paused
    /// Its memory lives in the bundle's save slot rather than in a session, so
    /// it survives quitting Kernova; resuming restores it.
    case suspended
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
    /// Not a case: it is not a runtime state a session can be in, and
    /// nothing but a listing ever sees it.
    public static let preparingWireName = "preparing"

    /// What a person reads for this status.
    public var displayName: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .paused: "Paused"
        case .suspended: "Suspended"
        case .saving: "Suspending"
        case .snapshotting: "Taking Snapshot"
        case .restoring: "Restoring"
        case .installing: "Installing"
        case .initialBoot: "Initial Boot"
        case .error: "Error"
        }
    }

    /// What a person reads for a VM in this status: ``heldByAnotherCopyDisplayName``
    /// when another copy of Kernova holds it, since the status this copy sees
    /// then says nothing about what the VM is doing.
    public func displayName(heldByAnotherCopy: Bool) -> String {
        heldByAnotherCopy ? Self.heldByAnotherCopyDisplayName : displayName
    }

    /// A status read off the wire, in the words a person reads, by the same
    /// rule as ``displayName(heldByAnotherCopy:)``.
    ///
    /// Answers for ``preparingWireName``, which is no case of this type, and
    /// falls back to the raw name for anything else — which only a peer from
    /// another vocabulary could send.
    public static func displayName(forWireName wireName: String, heldByAnotherCopy: Bool) -> String {
        if let known = VMStatus(rawValue: wireName) {
            return known.displayName(heldByAnotherCopy: heldByAnotherCopy)
        }
        if heldByAnotherCopy { return heldByAnotherCopyDisplayName }
        return wireName == preparingWireName ? "Preparing" : wireName
    }

    /// What a person reads in place of the status of a VM another running
    /// copy of Kernova holds: the copy answering sees it at rest, and cannot
    /// see what the other copy is doing with it.
    public static let heldByAnotherCopyDisplayName = "In use by another copy of Kernova"
}
