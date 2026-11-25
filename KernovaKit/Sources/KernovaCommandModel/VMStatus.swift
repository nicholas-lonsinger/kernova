import Foundation

/// The vocabulary a VM's runtime state is named in — the projection every
/// automation surface and every label reads off `VMLifecyclePhase`.
///
/// The raw value is the name every automation surface reads and writes;
/// ``displayName`` is what a person reads. Nothing is *decided* here: a
/// predicate belongs to the phase, which distinguishes the cases a status
/// conflates.
public enum VMStatus: String, Codable, CaseIterable, Sendable {
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
    /// A Force Stop was sent and the VM's process has not yet ended.
    case forceStopping
    /// VM exists in the library but has never completed its initial boot.
    /// Clicking Start kicks off the macOS install, then auto-boots.
    case initialBoot
    case error

    /// What a person reads for this status.
    public var displayName: String { words.name }

    /// This status as it reads after "is" in a sentence ("Tahoe is
    /// suspended.").
    public var phrase: String { words.phrase }

    /// What a person reads for a VM in this status: ``heldByAnotherCopyDisplayName``
    /// when another copy of Kernova holds it, since the status this copy sees
    /// then says nothing about what the VM is doing.
    public func displayName(heldByAnotherCopy: Bool) -> String {
        heldByAnotherCopy ? Self.heldByAnotherCopyDisplayName : displayName
    }

    /// What a person reads in place of the status of a VM another running
    /// copy of Kernova holds: the copy answering sees it at rest, and cannot
    /// see what the other copy is doing with it.
    public static let heldByAnotherCopyDisplayName = heldByAnotherCopyWords.name

    // MARK: - Words

    /// One status in both of the forms a person reads it in: a label, and
    /// the phrase a sentence carries — each spelled out, since a label's case
    /// is not a sentence's ("Kernova" stays capitalized mid-sentence).
    struct Words {
        let name: String
        let phrase: String
    }

    static let heldByAnotherCopyWords = Words(
        name: "In use by another copy of Kernova", phrase: "in use by another copy of Kernova")

    var words: Words {
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
        case .forceStopping: Words(name: "Force Stopping", phrase: "force stopping")
        case .initialBoot: Words(name: "Initial Boot", phrase: "not yet booted")
        case .error: Words(name: "Error", phrase: "in an error state")
        }
    }
}

/// The status a listing or a read reports for a VM: a VM in the library's
/// runtime ``VMStatus``, or ``preparing`` while a create, clone or import is
/// still writing its bundle — which is no runtime state a session can be in.
///
/// Coded as one string, its ``rawValue``: the status's own, or `preparing`.
public enum VMReportedStatus: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
    /// A VM in the library, in this runtime state.
    case runtime(VMStatus)
    /// A VM whose bundle a create, clone or import is still writing.
    case preparing

    public static let allCases: [VMReportedStatus] = VMStatus.allCases.map(Self.runtime) + [.preparing]

    private static let preparingRawValue = "preparing"

    /// The name every automation surface reads this status by.
    public var rawValue: String {
        switch self {
        case .runtime(let status): status.rawValue
        case .preparing: Self.preparingRawValue
        }
    }

    /// The status `rawValue` names, `nil` for a name no case has.
    public init?(rawValue: String) {
        if rawValue == Self.preparingRawValue {
            self = .preparing
        } else if let status = VMStatus(rawValue: rawValue) {
            self = .runtime(status)
        } else {
            return nil
        }
    }

    /// What a person reads for a VM reporting this status, by the rule
    /// ``VMStatus/displayName(heldByAnotherCopy:)`` states.
    public func displayName(heldByAnotherCopy: Bool) -> String {
        words(heldByAnotherCopy: heldByAnotherCopy).name
    }

    /// This status as it reads after "is" in a sentence, by the same rule.
    public func phrase(heldByAnotherCopy: Bool) -> String {
        words(heldByAnotherCopy: heldByAnotherCopy).phrase
    }

    private func words(heldByAnotherCopy: Bool) -> VMStatus.Words {
        if heldByAnotherCopy { return VMStatus.heldByAnotherCopyWords }
        return switch self {
        case .runtime(let status): status.words
        case .preparing: VMStatus.Words(name: "Preparing", phrase: "preparing")
        }
    }
}
