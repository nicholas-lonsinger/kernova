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
    /// What the guest's address resolves to on the network its mode joins.
    public let ipAddress: GuestIPAddress

    /// Names one VM.
    public init(id: UUID, name: String, status: String, ipAddress: GuestIPAddress) {
        self.id = id
        self.name = name
        self.status = status
        self.ipAddress = ipAddress
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
    /// What the guest's address resolves to on the network its mode joins.
    public let ipAddress: GuestIPAddress
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
        ipAddress: GuestIPAddress,
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
    /// The guest had not powered off `seconds` after the shutdown request, so
    /// the verb stopped waiting and left the VM as it was.
    case timedOut(vm: VMSummary, verb: VMVerb, seconds: TimeInterval)
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

/// How every surface words a refusal.
///
/// The copy lives on the wire type rather than on the app's own error, because
/// every door that shows it — an AppKit alert, Shortcuts, the `kernova` tool —
/// can hold one of these and only one of them can hold the app's. Rendering it
/// twice is how two doors come to say different things about the same refusal.
extension CommandErrorDTO {
    /// The heading a surface shows this refusal under.
    public var title: String {
        switch self {
        case .notFound, .ambiguous, .busy, .unsupported, .invalidState, .timedOut:
            "Error"
        case .confirmationRequired(let prompt):
            prompt.title
        case .conflict(_, _, let reason):
            switch reason {
            case .machineIdentity: "Duplicate Machine ID"
            case .macAddress: "Duplicate MAC Address"
            }
        case .operationFailed(_, let title, _, _):
            title ?? "Error"
        }
    }

    /// What a surface tells the user, in one sentence per fact.
    public var message: String {
        switch self {
        case .notFound(let selector):
            "No virtual machine named \u{201C}\(selector.displayText)\u{201D}."
        case .ambiguous(let selector, let candidates):
            "\u{201C}\(selector.displayText)\u{201D} names \(candidates.count) virtual machines. "
                + "Use one of their identifiers instead: "
                + candidates.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
                + "."
        case .invalidState(let vm, let current, let allowed):
            // Display names, never the raw values: those are the wire's
            // vocabulary, and this sentence goes in front of a person. A verb
            // every state admits is left out, since naming it says nothing.
            {
                let offered = allowed.filter { !$0.isAdmittedInEveryState }.map(\.displayName)
                let state = VMStatus.displayName(forWireName: current).lowercased()
                return "\u{201C}\(vm.name)\u{201D} is \(state). "
                    + (offered.isEmpty
                        ? "Nothing can be done with it in that state."
                        : "What it accepts now: \(offered.joined(separator: ", ")).")
            }()
        case .busy(let vm, let operation):
            "\u{201C}\(vm.name)\u{201D} is busy \(operation). Wait for it to finish, then try again."
        case .confirmationRequired(let prompt):
            prompt.message
        case .unsupported(let capability):
            "This virtual machine does not support \(capability)."
        case .conflict(let vm, let other, let reason):
            switch reason {
            case .machineIdentity:
                "\u{201C}\(vm.name)\u{201D} has the same machine ID as \u{201C}\(other.name)\u{201D}, which is active. "
                    + "Two virtual machines with the same machine ID must not run at once. "
                    + "Stop \u{201C}\(other.name)\u{201D} first, or allow this in Settings \u{2192} Advanced."
            case .macAddress:
                "\u{201C}\(vm.name)\u{201D} has the same MAC address as \u{201C}\(other.name)\u{201D}, which is active. "
                    + "Two virtual machines with the same MAC address must not run on the same network at once. "
                    + "Stop \u{201C}\(other.name)\u{201D} first, or give one of them a new address in Network settings."
            }
        case .timedOut(let vm, let verb, let seconds):
            "\u{201C}\(vm.name)\u{201D} did not shut down within "
                + "\(Self.deadlineText(seconds)) seconds"
                + (verb == .restart
                    ? ", so it was not started again. " : " and is running unchanged. ")
                + "A force stop terminates a guest that ignores a shutdown request, losing "
                + "anything unsaved inside it."
        case .operationFailed(_, _, let message, _):
            message
        }
    }

    /// `seconds` written the way a person types a deadline: whole where it is
    /// whole, one decimal otherwise.
    private static func deadlineText(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded()
            ? String(format: "%.0f", seconds) : String(format: "%.1f", seconds)
    }
}
