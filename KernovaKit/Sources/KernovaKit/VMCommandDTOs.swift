import Foundation

/// One VM, as much of it as any refusal or listing needs to name it.
///
/// The facade's own result type, not a serialization mirror of one: the wire
/// envelope encodes this value directly, so a listing and an ambiguity refusal
/// describe a VM identically whichever door asked.
public struct VMSummary: Codable, Sendable, Hashable {
    /// The VM's stable identifier.
    public let id: UUID
    /// The VM's display name, which is not unique.
    public let name: String
    /// The VM's runtime status, as its stable wire name. A VM whose bundle is
    /// still being written by a create, clone or import reports `preparing`,
    /// which is not a ``VMStatus`` value.
    public let status: String

    /// Names one VM.
    public init(id: UUID, name: String, status: String) {
        self.id = id
        self.name = name
        self.status = status
    }
}

/// Everything an `info` read answers about one VM.
public struct VMInfo: Codable, Sendable, Hashable {
    /// The VM's stable identifier.
    public let id: UUID
    /// The VM's display name.
    public let name: String
    /// The VM's runtime status, as its stable wire name. A VM whose bundle is
    /// still being written by a create, clone or import reports `preparing`,
    /// which is not a ``VMStatus`` value.
    public let status: String
    /// Which guest the VM runs, as its stable wire name.
    public let guestOS: String
    /// Virtual CPUs the guest is configured with.
    public let cpuCount: Int
    /// Guest memory in bytes.
    public let memoryBytes: UInt64
    /// The main disk's configured size in gigabytes.
    public let diskSizeInGB: Int
    /// The network the VM joins, `nil` when networking is off.
    public let networkMode: String?
    /// The address the guest presents on that network.
    public let macAddress: String?
    /// The address the app reserved for this guest, `nil` when it has none to
    /// report — networking off, an externally addressed bridge, or a build
    /// whose reservation machinery is absent.
    public let ipAddress: String?
    /// The guest agent's install and connectivity state, as its wire name.
    public let agentStatus: String
    /// Whether the bundle holds a suspended session.
    public let hasSavedState: Bool
    /// Whether the VM returns to a baseline snapshot on every power-off.
    public let isEphemeral: Bool
    /// How many named restore points the bundle holds.
    public let snapshotCount: Int
    /// Where the VM's bundle lives.
    public let bundlePath: String

    /// Describes one VM.
    public init(
        id: UUID,
        name: String,
        status: String,
        guestOS: String,
        cpuCount: Int,
        memoryBytes: UInt64,
        diskSizeInGB: Int,
        networkMode: String?,
        macAddress: String?,
        ipAddress: String?,
        agentStatus: String,
        hasSavedState: Bool,
        isEphemeral: Bool,
        snapshotCount: Int,
        bundlePath: String
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.guestOS = guestOS
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskSizeInGB = diskSizeInGB
        self.networkMode = networkMode
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.agentStatus = agentStatus
        self.hasSavedState = hasSavedState
        self.isEphemeral = isEphemeral
        self.snapshotCount = snapshotCount
        self.bundlePath = bundlePath
    }
}

/// One of a VM's named restore points.
public struct SnapshotSummary: Codable, Sendable, Hashable {
    /// The snapshot's stable identifier.
    public let id: UUID
    /// What the user called it.
    public let name: String
    /// The user's free-form note, empty when there is none.
    public let notes: String
    /// `warm` when the capture holds the guest's memory, `cold` when it holds
    /// the disks alone.
    public let kind: String
    /// When the capture was taken.
    public let createdAt: Date
    /// Whether the VM's state descends from this snapshot.
    public let isCurrent: Bool
    /// Whether this snapshot is the VM's Ephemeral Mode baseline, which cannot
    /// be deleted while the mode names it.
    public let isEphemeralBaseline: Bool

    /// Describes one restore point.
    public init(
        id: UUID,
        name: String,
        notes: String,
        kind: String,
        createdAt: Date,
        isCurrent: Bool,
        isEphemeralBaseline: Bool
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.kind = kind
        self.createdAt = createdAt
        self.isCurrent = isCurrent
        self.isEphemeralBaseline = isEphemeralBaseline
    }
}

/// What kind of consent a refusal is asking for, so a surface can pick its
/// native affordance without parsing the copy.
public enum ConfirmationKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Terminating a VM immediately, or discarding a suspended session.
    case forceStop
    /// Shutting down a guest that is paused and cannot receive the request.
    case stopPaused
    /// Deleting a VM's bundle.
    case deleteVM
    /// Trashing one snapshot's captured files.
    case deleteSnapshot
    /// Returning a VM to a snapshot.
    case revertToSnapshot
    /// Stopping a create, clone or import that is still writing.
    case cancelPreparing
    /// Interrupting a running guest setup — a macOS install, or a Linux
    /// installer image being fetched or verified.
    case cancelGuestSetup
    /// Detaching one storage disk or removable medium and trashing the file
    /// behind it.
    case removeAttachment
}

/// A second way to satisfy a confirmation, beside its own confirm action.
public struct ConfirmationAlternative: Codable, Sendable, Hashable {
    /// What the user sees on the button.
    public let title: String
    /// The disposition re-issuing the verb with satisfies this alternative,
    /// `nil` when the alternative changes no disposition.
    public let disposition: StopDisposition?
    /// Whether re-issuing with a checkpoint capture satisfies this alternative.
    public let takesCheckpoint: Bool

    /// Offers one alternative way to satisfy a confirmation.
    public init(title: String, disposition: StopDisposition? = nil, takesCheckpoint: Bool = false) {
        self.title = title
        self.disposition = disposition
        self.takesCheckpoint = takesCheckpoint
    }
}

/// What confirming a refused command entails, as data.
///
/// The core presents nothing: it describes the confirmation and leaves each
/// surface to gather it — an AppKit sheet, a wire client's own consent — then
/// re-issue the verb with `confirmed: true`.
public struct ConfirmationPrompt: Codable, Sendable, Hashable {
    /// Which confirmation this is.
    public let kind: ConfirmationKind
    /// The heading a surface shows it under.
    public let title: String
    /// What confirming does, in the words the user reads.
    public let message: String
    /// The confirm action's title.
    public let confirmTitle: String
    /// The title of the action that walks away, worded for what declining
    /// leaves running.
    public let dismissTitle: String
    /// Other ways to satisfy the confirmation, each re-issuing the verb
    /// differently.
    public let alternatives: [ConfirmationAlternative]

    /// Describes one confirmation.
    public init(
        kind: ConfirmationKind,
        title: String,
        message: String,
        confirmTitle: String,
        dismissTitle: String,
        alternatives: [ConfirmationAlternative] = []
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.dismissTitle = dismissTitle
        self.alternatives = alternatives
    }
}

/// A command failure, as it crosses a wire.
///
/// The in-process vocabulary carries one payload this cannot: a recovery a
/// caller performs by acting on the app's own model. That collapses to
/// ``CommandRecoveryDTO`` here, which names the recovery without handing over
/// the object it acts on.
public enum CommandErrorDTO: Codable, Sendable, Hashable {
    /// No VM answers to the selector.
    case notFound(selector: VMSelector)
    /// More than one VM answers to the selector.
    case ambiguous(selector: VMSelector, candidates: [VMSummary])
    /// The VM's current state does not admit the verb.
    case invalidState(vm: VMSummary, current: String, allowed: [VMVerb])
    /// The VM has work in flight that the verb would race.
    case busy(vm: VMSummary, operation: String)
    /// The verb is destructive and no consent was supplied.
    case confirmationRequired(prompt: ConfirmationPrompt)
    /// This build, guest, or configuration cannot do what was asked.
    case unsupported(capability: String)
    /// Running the VM would put two guests on one identity.
    case conflict(vm: VMSummary, with: VMSummary, reason: ConflictReason)
    /// The verb ran and did not complete. `title` is the heading the failure
    /// names for itself, `nil` when it has none of its own.
    case operationFailed(
        verb: VMVerb, title: String?, message: String, recovery: CommandRecoveryDTO?)
}

/// A recovery a failed command offers, named for a caller that cannot hold the
/// app-side object the in-process recovery carries.
public enum CommandRecoveryDTO: Codable, Sendable, Hashable {
    /// The start failed opening one attachment; removing that attachment (the
    /// file is untouched) and starting again is the offered way out.
    case removeStartFailedAttachment(id: UUID, label: String)
}
