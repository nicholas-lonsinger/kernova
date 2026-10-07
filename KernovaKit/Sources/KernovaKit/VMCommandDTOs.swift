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
    /// Whether the app last found another running copy of Kernova holding the
    /// VM, which is at rest in the copy answering.
    public let heldByAnotherCopy: Bool

    /// Names one VM.
    public init(
        id: UUID, name: String, status: String, ipAddress: GuestIPAddress,
        heldByAnotherCopy: Bool
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.ipAddress = ipAddress
        self.heldByAnotherCopy = heldByAnotherCopy
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
    /// Which network of its mode the VM joins — `common`, `isolated`, or a
    /// named network's identifier, as `network.membership` reads it — `nil`
    /// where it joins no app-managed network (networking off, or bridged).
    public let networkMembership: String?
    /// The name of the named network the VM joins, `nil` where it joins none
    /// or one the library does not list.
    public let networkName: String?
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
    /// Whether the bundle holds any snapshot — ``snapshotCount`` is not zero.
    public let hasSnapshots: Bool
    /// How a macOS guest's agent stands against the one the app bundles, `nil`
    /// for a guest no Kernova agent runs in.
    public let guestAgent: VMGuestAgentBucket?
    /// The coarse state the VM is in, by whether a session is live in the
    /// copy answering.
    public let stateBucket: VMStateBucket
    /// Where the VM's bundle lives.
    public let bundlePath: String
    /// Whether the app last found another running copy of Kernova holding the
    /// VM, which is at rest in the copy answering.
    public let heldByAnotherCopy: Bool

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
        networkMembership: String?,
        networkName: String?,
        macAddress: String?,
        ipAddress: GuestIPAddress,
        agentStatus: String,
        hasSavedState: Bool,
        isEphemeral: Bool,
        snapshotCount: Int,
        hasSnapshots: Bool,
        guestAgent: VMGuestAgentBucket?,
        stateBucket: VMStateBucket,
        bundlePath: String,
        heldByAnotherCopy: Bool
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.guestOS = guestOS
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskSizeInGB = diskSizeInGB
        self.networkMode = networkMode
        self.networkMembership = networkMembership
        self.networkName = networkName
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.agentStatus = agentStatus
        self.hasSavedState = hasSavedState
        self.isEphemeral = isEphemeral
        self.snapshotCount = snapshotCount
        self.hasSnapshots = hasSnapshots
        self.guestAgent = guestAgent
        self.stateBucket = stateBucket
        self.bundlePath = bundlePath
        self.heldByAnotherCopy = heldByAnotherCopy
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
    /// `warm` when the capture holds the guest's memory, `cold` when it does
    /// not.
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

/// One folder a VM shares with its guest.
///
/// The app's `SharedDirectory` without the security-scoped bookmark behind it:
/// that is authority this process holds and cannot hand over, and no client
/// could act on it. The path is what the share is addressed by, here and in the
/// edit that drops it.
public struct SharedDirectorySummary: Codable, Sendable, Hashable {
    /// The folder's path, as this Mac names it.
    public let path: String
    /// Whether the guest may read the folder but not write to it.
    public let readOnly: Bool

    /// Describes one share.
    public init(path: String, readOnly: Bool) {
        self.path = path
        self.readOnly = readOnly
    }
}

/// One USB accessory macOS has assigned to Kernova, and where it currently is.
///
/// `name` is what the device calls itself — its vendor and product strings —
/// falling back to `VID:PID · class` for one that reports neither, and
/// qualified by the port where two accessories would otherwise read alike.
public struct USBAccessorySummary: Codable, Sendable, Hashable {
    /// The accessory's IORegistry ID, and what an attach names it by. Valid
    /// only while this Kernova process keeps holding the accessory.
    public let registryID: UInt64
    /// What a surface calls this accessory.
    public let name: String
    /// `idVendor` from the device descriptor.
    public let vendorID: UInt16
    /// `idProduct` from the device descriptor.
    public let productID: UInt16
    /// The attachment's device UUID while a guest holds this accessory, and
    /// what a detach names it by; `nil` when it is available to attach.
    public let deviceID: UUID?

    /// Describes one accessory.
    public init(
        registryID: UInt64, name: String, vendorID: UInt16, productID: UInt16,
        deviceID: UUID? = nil
    ) {
        self.registryID = registryID
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.deviceID = deviceID
    }
}

/// One USB accessory a virtual machine takes back automatically.
///
/// Unlike ``USBAccessorySummary``, every field here survives the accessory
/// being unplugged: these rows describe hardware that is usually in a drawer,
/// which is why they can be listed and removed at all.
public struct USBPairingSummary: Codable, Sendable, Hashable {
    /// The virtual machine that takes this accessory back.
    public let vm: String
    /// The durable key the accessory answers to, and what `usb forget` takes
    /// back. Stable across a replug and a restart.
    public let key: String
    /// What a surface calls this accessory, qualified by the port when the rule
    /// names one port in particular.
    public let name: String
    /// When the accessory was last passed through to that virtual machine.
    public let pairedAt: Date

    /// Describes one remembered accessory.
    public init(vm: String, key: String, name: String, pairedAt: Date) {
        self.vm = vm
        self.key = key
        self.name = name
        self.pairedAt = pairedAt
    }
}

/// The mode every virtual machine on a named network runs in.
public enum NetworkKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Shared Network: the guests reach the internet through this Mac.
    case shared
    /// Host Only: the guests reach this Mac and each other, nothing else.
    case hostOnly
}

/// One named network: the virtual machines on it reach each other, and no
/// other guest.
public struct NetworkSummary: Codable, Sendable, Hashable {
    /// The network's stable identifier, which a virtual machine's
    /// `network.membership` names.
    public let id: UUID
    /// What the user called it, unique in the library.
    public let name: String
    /// The mode every virtual machine on it runs in.
    public let kind: NetworkKind
    /// The virtual machines that join it, in library order.
    public let members: [VMSummary]

    /// Describes one named network.
    public init(id: UUID, name: String, kind: NetworkKind, members: [VMSummary]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.members = members
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
    /// Letting the guest read whatever is copied on the host, continuously.
    case enableClipboardPassthrough
    /// Starting a VM while another one with the same machine identity is
    /// active.
    case startBesideSharedMachineIdentity
}

/// The confirmations a caller has given for one call of a verb.
///
/// A set rather than a yes, because one call can need more than one — a revert
/// that resumes beside a VM sharing its machine identity needs both — and each
/// is asked with its own consequence in front of the user.
public struct Consent: Codable, Sendable, Hashable {
    /// The confirmations given.
    public let kinds: Set<ConfirmationKind>

    /// Gives the confirmations in `kinds`.
    public init(_ kinds: Set<ConfirmationKind>) {
        self.kinds = kinds
    }

    /// No confirmation given.
    public static let none = Consent([])
    /// Every confirmation given — what a door that consents up front, such as
    /// `--yes`, answers.
    public static let all = Consent(Set(ConfirmationKind.allCases))

    /// Whether `kind` was confirmed.
    public func covers(_ kind: ConfirmationKind) -> Bool {
        kinds.contains(kind)
    }

    /// These confirmations, and `kind` too.
    public func adding(_ kind: ConfirmationKind) -> Consent {
        Consent(kinds.union([kind]))
    }
}

/// A second way to satisfy a confirmation, beside its own confirm action.
public struct ConfirmationAlternative: Codable, Sendable, Hashable {
    /// What the user sees on the button.
    public let title: String
    /// Whether taking this route discards something, so a surface tints it and
    /// keeps it off the Return key.
    public let isDestructive: Bool
    /// The disposition re-issuing the verb with satisfies this alternative,
    /// `nil` when the alternative changes no disposition.
    public let disposition: StopDisposition?
    /// Whether re-issuing with a checkpoint capture satisfies this alternative.
    public let takesCheckpoint: Bool
    /// Whether re-issuing without trashing the file behind the attachment
    /// satisfies this alternative.
    public let keepsFile: Bool

    /// Offers one alternative way to satisfy a confirmation.
    public init(
        title: String,
        isDestructive: Bool = false,
        disposition: StopDisposition? = nil,
        takesCheckpoint: Bool = false,
        keepsFile: Bool = false
    ) {
        self.title = title
        self.isDestructive = isDestructive
        self.disposition = disposition
        self.takesCheckpoint = takesCheckpoint
        self.keepsFile = keepsFile
    }
}

/// What confirming a refused command entails, as data.
///
/// The core presents nothing: it describes the confirmation and leaves each
/// surface to gather it — an AppKit sheet, a wire client's own consent — then
/// re-issue the verb with ``kind`` in its ``Consent``.
public struct ConfirmationPrompt: Codable, Sendable, Hashable {
    /// Which confirmation this is.
    public let kind: ConfirmationKind
    /// The heading a surface shows it under.
    public let title: String
    /// What confirming does, in the words the user reads.
    public let message: String
    /// The confirm action's title.
    public let confirmTitle: String
    /// Whether confirming discards or risks something, so a surface tints the
    /// action and keeps it off the Return key. A confirmation is raised for a
    /// destructive verb by definition; the gentle routes opt out.
    public let confirmIsDestructive: Bool
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
        confirmIsDestructive: Bool = true,
        dismissTitle: String,
        alternatives: [ConfirmationAlternative] = []
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.confirmIsDestructive = confirmIsDestructive
        self.dismissTitle = dismissTitle
        self.alternatives = alternatives
    }
}

/// The account a start is waiting for a password for, as data.
///
/// The second thing a verb refuses without and takes as a parameter, beside
/// ``ConfirmationPrompt``: the core describes what it is asking for and leaves
/// the app to gather it — a sheet, a launch pass — then re-issue the start
/// with an answer. In-process only: the wire carries no way to answer this, so
/// every out-of-process caller simply gets the refusal.
///
/// Carries no password and never will: the bundle stores the other four fields
/// of the account (its name, its username, and what it does on login), and the
/// secret exists only inside the call that supplies it.
public struct GuestAccountPrompt: Codable, Sendable, Hashable {
    /// The VM whose start is waiting.
    public let vm: VMSummary
    /// The account's short name — what the user logs in as.
    public let username: String
    /// The account's full name, as the guest will display it.
    public let fullName: String
    /// What a surface tells the user, in the words they read.
    public let message: String

    /// Describes one account a start is waiting on.
    public init(vm: VMSummary, username: String, fullName: String, message: String) {
        self.vm = vm
        self.username = username
        self.fullName = fullName
        self.message = message
    }
}

/// A change to a VM's network that removes a MAC address conflict: another
/// active VM uses the VM's MAC address on the network the VM would join. Each
/// is a change to the VM's configuration, and none runs both VMs on one
/// network.
public enum MACAddressRemedy: String, Codable, Sendable, Hashable, CaseIterable {
    /// Joins a network of its own in its mode, which no other VM shares.
    case ownNetwork
    /// Takes a new MAC address.
    case newAddress
    /// Takes the network device away.
    case noNetwork
}

/// One way out of a MAC address conflict, as a surface offers it.
public struct MACAddressRemedyOffer: Codable, Sendable, Hashable {
    /// What re-issuing the verb with this remedy changes.
    public let remedy: MACAddressRemedy
    /// What the user sees on the button.
    public let title: String
    /// Whether taking it discards the VM's saved state, so a surface tints it
    /// and keeps it off the Return key.
    public let isDestructive: Bool

    /// Offers one remedy.
    public init(remedy: MACAddressRemedy, title: String, isDestructive: Bool) {
        self.remedy = remedy
        self.title = title
        self.isDestructive = isDestructive
    }
}

/// What a refusal over a MAC address conflict offers, as data.
///
/// A choice among changes rather than a yes, so it is not a
/// ``ConfirmationPrompt``: a surface shows ``offers`` and re-issues ``verb``
/// with the chosen remedy.
public struct MACAddressRemedyPrompt: Codable, Sendable, Hashable {
    /// The VM being brought up or edited.
    public let vm: VMSummary
    /// The active VM using the same MAC address on that network.
    public let other: VMSummary
    /// The verb that applies a remedy when re-issued with one.
    public let verb: VMVerb
    /// The heading a surface shows it under.
    public let title: String
    /// What the user reads above the offers.
    public let message: String
    /// The remedies this VM can take, in the order a surface shows them.
    public let offers: [MACAddressRemedyOffer]
    /// The title of the action that walks away.
    public let dismissTitle: String

    /// Describes one MAC address conflict and its ways out.
    public init(
        vm: VMSummary, other: VMSummary, verb: VMVerb, title: String, message: String,
        offers: [MACAddressRemedyOffer], dismissTitle: String
    ) {
        self.vm = vm
        self.other = other
        self.verb = verb
        self.title = title
        self.message = message
        self.offers = offers
        self.dismissTitle = dismissTitle
    }
}

/// A removal that happened, and the files it was asked to take that stayed.
///
/// Neither a success nor a refusal: what the verb was mainly asked to remove
/// is gone, so repeating it names nothing.
public struct FilesKept: Codable, Sendable, Hashable {
    /// What the verb removed.
    public enum Removal: Codable, Sendable, Hashable {
        /// A virtual machine, moved to the Trash or, `permanently`, deleted.
        case vm(name: String, permanently: Bool)
        /// An attachment's entry, dropped from the virtual machine `vm`; its
        /// file was to be moved to the Trash.
        case attachment(label: String, vm: String)

        /// Whether the files were to be deleted rather than moved to the
        /// Trash.
        var deletes: Bool {
            if case .vm(_, permanently: true) = self { return true }
            return false
        }
    }

    /// One file a removal could not take.
    public struct File: Codable, Sendable, Hashable {
        /// The path the removal addressed.
        public let path: String
        /// Why the file could not be removed, in the system's words.
        public let reason: String

        /// Names one file that stayed.
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// What the verb removed.
    public let removal: Removal
    /// The files that stayed, never empty.
    public let files: [File]

    /// Describes a removal that kept `files`, or `nil` when it kept none — a
    /// removal that took every file it was asked to is a success.
    public init?(_ removal: Removal, kept files: [File]) {
        guard !files.isEmpty else { return nil }
        self.removal = removal
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case removal, files
    }

    /// Decodes a removal that kept files, refusing one that names none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let removal = try container.decode(Removal.self, forKey: .removal)
        let files = try container.decode([File].self, forKey: .files)
        guard let kept = FilesKept(removal, kept: files) else {
            throw DecodingError.dataCorruptedError(
                forKey: .files, in: container, debugDescription: "A removal that kept no file.")
        }
        self = kept
    }

    /// The heading a surface shows this outcome under.
    var title: String {
        let action = removal.deletes ? "Delete" : "Move"
        let object = files.count == 1 ? "a File" : "\(files.count) Files"
        let destination = removal.deletes ? "" : " to the Trash"
        return "Couldn\u{2019}t \(action) \(object)\(destination)"
    }

    /// What happened, then each file that stayed and why.
    var message: String {
        let done =
            switch removal {
            case .vm(let name, let permanently):
                "\u{201C}\(name)\u{201D} was \(permanently ? "deleted" : "moved to the Trash")."
            case .attachment(let label, let vm):
                "\u{201C}\(label)\u{201D} was removed from \u{201C}\(vm)\u{201D}."
            }
        let missed = removal.deletes ? "was not deleted" : "was not moved to the Trash"
        let sentences = files.map { file in
            let ending = file.reason.last.map { ".!?".contains($0) } == true ? "" : "."
            return "\u{201C}\(file.path)\u{201D} \(missed): \(file.reason)\(ending)"
        }
        return ([done] + sentences).joined(separator: " ")
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
    /// The VM's current state does not admit the verb. `settings` names the
    /// assignments a refused `setConfiguration` would have made, empty for
    /// every other verb.
    case invalidState(
        vm: VMSummary, current: String, allowed: [VMVerb], settings: [ConfigurationEntry] = [])
    /// The VM's current state takes the verb, but not this change of it: only
    /// a stopped VM takes `change`.
    case changeTakesStoppedVM(vm: VMSummary, current: String, change: StoppedVMChange)
    /// The VM has work in flight that the verb would race.
    case busy(vm: VMSummary, operation: String)
    /// Another running copy of Kernova holds the VM.
    case heldByAnotherCopy(vm: VMSummary)
    /// The verb is destructive and no consent was supplied.
    case confirmationRequired(prompt: ConfirmationPrompt)
    /// The start would spend the one boot macOS creates a guest account on, and
    /// no answer about that account was supplied.
    case guestAccountPasswordRequired(prompt: GuestAccountPrompt)
    /// Another active VM uses the VM's MAC address on the network it would
    /// join, and the verb takes a change to the VM's network that removes the
    /// conflict.
    case macAddressRemedyRequired(prompt: MACAddressRemedyPrompt)
    /// An argument named something the verb does not offer, or carried a value
    /// it cannot use. `message` is the whole refusal.
    case invalidArgument(message: String)
    /// This build, guest, or configuration cannot do what was asked.
    case unsupported(capability: String)
    /// This build cannot do what was asked: the cause is the build, whatever
    /// VM the verb named, so the refusal names no virtual machine.
    case unsupportedByBuild(capability: String)
    /// The VM answered; something the verb named *on* it did not. `item` is
    /// what was looked for, in the words the user reads.
    case itemNotFound(vm: VMSummary, item: String)
    /// Something the verb named on the host did not answer, and no VM was
    /// named — a USB accessory macOS has not assigned to Kernova, where naming
    /// a virtual machine would describe something the caller never asked about.
    case itemNotFoundOnHost(item: String)
    /// Running the VM would put two guests on one identity.
    case conflict(vm: VMSummary, with: VMSummary, reason: ConflictReason)
    /// The app is quitting, and takes nothing new on.
    case terminating
    /// The guest had not powered off `seconds` after the shutdown request, so
    /// the verb stopped waiting and left the VM as it was.
    case timedOut(vm: VMSummary, verb: VMVerb, seconds: TimeInterval)
    /// The verb ran and did not complete. `title` is the heading the failure
    /// names for itself, `nil` when it has none of its own.
    case operationFailed(
        verb: VMVerb, title: String?, message: String, recovery: CommandRecoveryDTO?)
    /// The verb removed what it was mainly asked to, and the files it names
    /// stayed.
    case filesKept(FilesKept)
}

/// What a verb does that only a stopped VM takes, though the verb itself is
/// taken in more states.
public enum StoppedVMChange: String, Codable, Sendable, Hashable, CaseIterable {
    /// Adding a guest's first shared directory or removing its last, which
    /// adds or removes the device every share rides.
    case firstOrLastSharedDirectory
    /// Cloning a VM whose guest can write to a disk outside its bundle.
    case cloneWritingOutsideBundle
    /// Snapshotting a VM whose guest can write to a disk outside its bundle.
    case snapshotWritingOutsideBundle

    /// The rule, as every surface states it.
    public var sentence: String {
        switch self {
        case .firstOrLastSharedDirectory:
            "Adding the first share or removing the last needs the virtual machine stopped."
        case .cloneWritingOutsideBundle:
            "Cloning a virtual machine with a writable external disk needs it stopped."
        case .snapshotWritingOutsideBundle:
            "Taking a snapshot of a virtual machine with a writable external disk needs it stopped."
        }
    }
}

/// A recovery a failed command offers, named for a caller that cannot hold the
/// app-side object the in-process recovery carries.
public enum CommandRecoveryDTO: Codable, Sendable, Hashable {
    /// A start or resume failed on one attachment; removing that entry (the
    /// file or folder is untouched) and starting again is the offered way out.
    case removeStartFailedAttachment(id: UUID, label: String)
}

extension ConflictReason {
    /// The heading a refusal over this reason is shown under.
    public var title: String {
        switch self {
        case .machineIdentity: "Duplicate Machine ID"
        case .macAddress: "Duplicate MAC Address"
        case .macAddressInUse: "MAC Address In Use"
        }
    }
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
        case .notFound, .itemNotFound, .itemNotFoundOnHost, .ambiguous, .busy, .heldByAnotherCopy,
            .unsupported, .unsupportedByBuild, .invalidState, .changeTakesStoppedVM, .timedOut,
            .invalidArgument, .terminating:
            "Error"
        case .confirmationRequired(let prompt):
            prompt.title
        case .guestAccountPasswordRequired(let prompt):
            "Couldn\u{2019}t Start \u{201C}\(prompt.vm.name)\u{201D}"
        case .macAddressRemedyRequired(let prompt):
            prompt.title
        case .conflict(_, _, let reason):
            reason.title
        case .operationFailed(_, let title, _, _):
            title ?? "Error"
        case .filesKept(let kept):
            kept.title
        }
    }

    /// What a surface tells the user, in one sentence per fact.
    public var message: String {
        switch self {
        case .notFound(let selector):
            "No virtual machine named \u{201C}\(selector.displayText)\u{201D}."
        case .itemNotFound(let vm, let item):
            "\u{201C}\(vm.name)\u{201D} has no \(item)."
        case .itemNotFoundOnHost(let item):
            "Kernova has no \(item)."
        case .ambiguous(let selector, let candidates):
            "\u{201C}\(selector.displayText)\u{201D} names \(candidates.count) virtual machines. "
                + "Use one of their identifiers instead: "
                + candidates.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
                + "."
        case .invalidState(let vm, let current, let allowed, let settings):
            // The status and the verbs in a person's words, never their raw values:
            // those are the wire's vocabulary, and this sentence goes in front
            // of a person. A refused setting is named by its key and the value
            // asked for, the spelling `set` takes. A verb every state admits is
            // left out, since naming it says nothing.
            {
                let offered = allowed.filter { !$0.isAdmittedInEveryState }.map(\.displayName)
                let state = VMStatus.phrase(forWireName: current, heldByAnotherCopy: false)
                let refused = settings.enumerated().map { index, entry in
                    index == 0
                        ? "\(entry.key) cannot be set to \u{201C}\(entry.value)\u{201D}"
                        : "\(entry.key) to \u{201C}\(entry.value)\u{201D}"
                }
                return "\u{201C}\(vm.name)\u{201D} is \(state)"
                    + (refused.isEmpty
                        ? ". "
                        : refused.count == 1
                            ? ", so \(refused[0]) while it is. "
                            : ", so \(refused.joined(separator: ", or ")), while it is. ")
                    + (offered.isEmpty
                        ? "Nothing can be done with it in that state."
                        : "What it accepts now: \(offered.joined(separator: ", ")).")
            }()
        case .changeTakesStoppedVM(let vm, let current, let change):
            "\u{201C}\(vm.name)\u{201D} is "
                + "\(VMStatus.phrase(forWireName: current, heldByAnotherCopy: false)). "
                + change.sentence
        case .busy(let vm, let operation):
            "\u{201C}\(vm.name)\u{201D} is busy \(operation). Wait for it to finish, then try again."
        case .heldByAnotherCopy(let vm):
            "\u{201C}\(vm.name)\u{201D} is in use by another copy of Kernova."
        case .confirmationRequired(let prompt):
            prompt.message
        case .guestAccountPasswordRequired(let prompt):
            prompt.message
        case .macAddressRemedyRequired(let prompt):
            // The refusal, for a door that does not show the offers.
            Self.conflictMessage(
                vm: prompt.vm.name, other: prompt.other.name,
                otherHeldByAnotherCopy: prompt.other.heldByAnotherCopy, reason: .macAddress)
        case .invalidArgument(let message):
            message
        case .unsupported(let capability):
            "This virtual machine does not support \(capability)."
        case .unsupportedByBuild(let capability):
            "This build of Kernova does not support \(capability)."
        case .conflict(let vm, let other, let reason):
            Self.conflictMessage(
                vm: vm.name, other: other.name, otherHeldByAnotherCopy: other.heldByAnotherCopy,
                reason: reason)
        case .terminating:
            "Kernova is quitting."
        case .timedOut(let vm, let verb, let seconds):
            // Only what the expiry observed. What state the VM is in is a
            // separate read, and any sentence guessing it here is wrong for
            // some VM that reached the deadline another way.
            "\u{201C}\(vm.name)\u{201D} did not power off within "
                + "\(Self.deadlineText(seconds)) seconds"
                + (verb == .restart ? ", so it was not started again. " : ". ")
                + "A force stop terminates a guest that will not shut down, losing anything "
                + "unsaved inside it."
        case .operationFailed(_, _, let message, _):
            message
        case .filesKept(let kept):
            kept.message
        }
    }

    /// What a ``conflict(vm:with:reason:)`` refusal of `vm` over `other` tells
    /// the user — public so a refusal raised before it becomes a command error
    /// words itself identically.
    ///
    /// `otherHeldByAnotherCopy` names a claim another running copy of Kernova
    /// makes, which this copy can neither see into nor stop.
    public static func conflictMessage(
        vm: String, other: String, otherHeldByAnotherCopy: Bool, reason: ConflictReason
    ) -> String {
        switch reason {
        case .macAddressInUse(let address, let holding, let otherHolders):
            macAddressInUseMessage(
                address, vm: vm, holder: other, holding: holding, otherHolders: otherHolders)
        case .machineIdentity:
            sharedMachineIdentitySentence(
                vm: vm, other: other, otherHeldByAnotherCopy: otherHeldByAnotherCopy)
                + " Two virtual machines with the same machine ID must not run at once."
                + (otherHeldByAnotherCopy ? "" : " Stop \u{201C}\(other)\u{201D} first.")
        case .macAddress:
            sharedMACAddressSentences(
                vm: vm, other: other, otherHeldByAnotherCopy: otherHeldByAnotherCopy) + " "
                + (otherHeldByAnotherCopy
                    ? "Change \u{201C}\(vm)\u{201D}\u{2019}s network or MAC address in Network settings."
                    : "Stop \u{201C}\(other)\u{201D} first, or change \u{201C}\(vm)\u{201D}\u{2019}s network or MAC address in Network settings.")
        }
    }

    /// The sentences naming the VM `vm` shares its MAC address with on one
    /// network, who is running it, and the rule they break — public so the
    /// question that offers changing `vm`'s network opens with the words its
    /// refusal does.
    public static func sharedMACAddressSentences(
        vm: String, other: String, otherHeldByAnotherCopy: Bool
    ) -> String {
        "\u{201C}\(vm)\u{201D} has the same MAC address as \u{201C}\(other)\u{201D}, "
            + (otherHeldByAnotherCopy ? "which another copy of Kernova is using. " : "which is active. ")
            + "Two virtual machines with the same MAC address must not run on the same network at once."
    }

    /// The sentence naming the VM `vm` shares its machine identity with, and
    /// who is running it — public so the confirmation that offers starting
    /// `vm` anyway opens with the words its refusal does.
    public static func sharedMachineIdentitySentence(
        vm: String, other: String, otherHeldByAnotherCopy: Bool
    ) -> String {
        "\u{201C}\(vm)\u{201D} has the same machine ID as \u{201C}\(other)\u{201D}, "
            + (otherHeldByAnotherCopy ? "which another copy of Kernova is using." : "which is active.")
    }

    /// `seconds` written the way a person types a deadline: whole where it is
    /// whole, one decimal otherwise.
    private static func deadlineText(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded()
            ? String(format: "%.0f", seconds) : String(format: "%.1f", seconds)
    }

    /// What ``ConflictReason/macAddressInUse(address:holding:otherHolders:)``
    /// tells the user: where each VM holds the address, then — only when one
    /// VM holds it and a step it can take certainly frees it — that step.
    ///
    /// An Ephemeral Mode baseline is named as one and offered no remedy: it
    /// cannot be deleted while the mode is on.
    private static func macAddressInUseMessage(
        _ address: String, vm: String, holder: String, holding: MACAddressHolding,
        otherHolders: [MACAddressHolder]
    ) -> String {
        let holders =
            [(name: holder, holding: holding)]
            + otherHolders.map { (name: $0.name, holding: $0.holding) }
        var sentences = holders.map { holdingSentence(address, name: $0.name, holding: $0.holding) }
        sentences.append("Each virtual machine needs its own MAC address.")
        if otherHolders.isEmpty,
            let remedy = remedy(name: holder, holding: holding, destination: vm)
        {
            sentences.append(remedy)
        }
        return sentences.joined(separator: " ")
    }

    /// One VM's hold on `address`, as the facts a refusal states.
    private static func holdingSentence(
        _ address: String, name: String, holding: MACAddressHolding
    ) -> String {
        let vm = "\u{201C}\(name)\u{201D}"
        let held: HeldSnapshots
        let facts: String
        switch holding {
        case .configuration:
            return "\(vm) already uses \(address)."
        case .snapshots(let snapshots):
            held = snapshots
            facts = "\(vm) has \(snapshotPhrase(snapshots)) taken with \(address)."
        case .configurationAndSnapshots(let snapshots):
            held = snapshots
            facts = "\(vm) already uses \(address), and has \(snapshotPhrase(snapshots)) taken with it."
        }
        guard let baseline = held.all.first(where: \.isEphemeralBaseline) else { return facts }
        return facts + " \u{201C}\(baseline.name)\u{201D} is its Ephemeral Mode baseline."
    }

    /// "a snapshot, “S”," or "snapshots “S1” and “S2”".
    private static func snapshotPhrase(_ snapshots: HeldSnapshots) -> String {
        let quoted = snapshots.all.map { "\u{201C}\($0.name)\u{201D}" }
        return quoted.count == 1 ? "a snapshot, \(quoted[0])," : "snapshots \(listed(quoted))"
    }

    /// The step that frees the address from its only holder, or `nil` when a
    /// snapshot holding it is a baseline no delete will take.
    private static func remedy(
        name: String, holding: MACAddressHolding, destination: String
    ) -> String? {
        let vm = "\u{201C}\(name)\u{201D}"
        let destination = "to move this address to \u{201C}\(destination)\u{201D}."
        switch holding {
        case .configuration:
            return "Change or delete \(vm) first \(destination)"
        case .snapshots(let snapshots):
            guard !snapshots.all.contains(where: \.isEphemeralBaseline) else { return nil }
            return "Delete \(snapshots.rest.isEmpty ? "that snapshot" : "those snapshots") first \(destination)"
        case .configurationAndSnapshots(let snapshots):
            guard !snapshots.all.contains(where: \.isEphemeralBaseline) else { return nil }
            let those = snapshots.rest.isEmpty ? "that snapshot" : "those snapshots"
            return "Delete \(vm), or change its address and delete \(those), \(destination)"
        }
    }

    /// `items` as a sentence lists them: "A", "A and B", "A, B and C".
    private static func listed(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
