import Foundation

/// The vocabulary a VM's runtime state is named in — the projection every
/// automation surface and every label reads off `VMLifecyclePhase`.
///
/// The raw value is the name every automation surface reads and writes;
/// ``displayName`` is what a person reads. Nothing is *decided* here: a
/// predicate belongs to the phase, which distinguishes the cases a status
/// conflates.
public enum VMStatus: String, CaseIterable, Sendable {
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
    /// Copying a live guest into a clone: the guest is paused while its disks
    /// are copied, then put back the way it was found.
    case cloning
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
    public var displayName: String { words.name }

    /// What a person reads for a VM in this status: ``heldByAnotherCopyDisplayName``
    /// when another copy of Kernova holds it, since the status this copy sees
    /// then says nothing about what the VM is doing.
    public func displayName(heldByAnotherCopy: Bool) -> String {
        Self.words(for: self, wireName: rawValue, heldByAnotherCopy: heldByAnotherCopy).name
    }

    /// A status read off the wire, in the words a person reads, by the same
    /// rule as ``displayName(heldByAnotherCopy:)``.
    ///
    /// Answers for ``preparingWireName``, which is no case of this type, and
    /// falls back to the raw name for anything else — which only a peer from
    /// another vocabulary could send.
    public static func displayName(forWireName wireName: String, heldByAnotherCopy: Bool) -> String {
        words(for: VMStatus(rawValue: wireName), wireName: wireName, heldByAnotherCopy: heldByAnotherCopy).name
    }

    /// The status as it reads after "is" in a sentence ("Tahoe is suspended."),
    /// by the same rule as ``displayName(heldByAnotherCopy:)``.
    public func phrase(heldByAnotherCopy: Bool) -> String {
        Self.words(for: self, wireName: rawValue, heldByAnotherCopy: heldByAnotherCopy).phrase
    }

    /// A status read off the wire as it reads after "is" in a sentence, by the
    /// same rule as ``displayName(forWireName:heldByAnotherCopy:)``.
    public static func phrase(forWireName wireName: String, heldByAnotherCopy: Bool) -> String {
        words(for: VMStatus(rawValue: wireName), wireName: wireName, heldByAnotherCopy: heldByAnotherCopy).phrase
    }

    /// What a person reads in place of the status of a VM another running
    /// copy of Kernova holds: the copy answering sees it at rest, and cannot
    /// see what the other copy is doing with it.
    public static let heldByAnotherCopyDisplayName = heldByAnotherCopyWords.name

    // MARK: - Words

    /// One status in both of the forms a person reads it in: a label, and
    /// the phrase a sentence carries — each spelled out, since a label's case
    /// is not a sentence's ("Kernova" stays capitalized mid-sentence).
    private struct Words {
        let name: String
        let phrase: String
    }

    private static let heldByAnotherCopyWords = Words(
        name: "In use by another copy of Kernova", phrase: "in use by another copy of Kernova")

    /// The words for a VM reporting `wireName` (`status` when it names a
    /// case): the held words whenever another copy holds it.
    private static func words(for status: VMStatus?, wireName: String, heldByAnotherCopy: Bool) -> Words {
        if heldByAnotherCopy { return heldByAnotherCopyWords }
        if let status { return status.words }
        if wireName == preparingWireName { return Words(name: "Preparing", phrase: "preparing") }
        return Words(name: wireName, phrase: wireName)
    }

    private var words: Words {
        switch self {
        case .stopped: Words(name: "Stopped", phrase: "stopped")
        case .starting: Words(name: "Starting", phrase: "starting")
        case .running: Words(name: "Running", phrase: "running")
        case .paused: Words(name: "Paused", phrase: "paused")
        case .suspended: Words(name: "Suspended", phrase: "suspended")
        case .saving: Words(name: "Suspending", phrase: "suspending")
        case .snapshotting: Words(name: "Taking Snapshot", phrase: "taking a snapshot")
        case .cloning: Words(name: "Cloning", phrase: "being cloned")
        case .restoring: Words(name: "Restoring", phrase: "restoring")
        case .installing: Words(name: "Installing", phrase: "installing")
        case .initialBoot: Words(name: "Initial Boot", phrase: "not yet booted")
        case .error: Words(name: "Error", phrase: "in an error state")
        }
    }
}
