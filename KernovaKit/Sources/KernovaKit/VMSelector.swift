import Foundation

/// How a caller names one virtual machine.
///
/// Display names are not unique, so a name that matches more than one VM
/// resolves to an ambiguity refusal carrying every candidate rather than to a
/// guess.
public enum VMSelector: Codable, Sendable, Hashable {
    /// The VM's stable identifier.
    case id(UUID)
    /// The VM's display name, matched exactly and case-sensitively.
    case name(String)
    /// Text typed by a user: read as an identifier when it parses as one and
    /// names a VM, otherwise as a display name.
    case idOrName(String)

    /// How this selector reads back in a message to the user.
    public var displayText: String {
        switch self {
        case .id(let id): id.uuidString
        case .name(let name), .idOrName(let name): name
        }
    }
}

/// One command in the facade's vocabulary.
///
/// Named rather than described so a refusal can list the verbs a VM's current
/// state does allow, and so each transport can map a verb to its own naming.
public enum VMVerb: String, Codable, Sendable, Hashable, CaseIterable {
    case list
    case info
    case ipAddress
    case snapshots
    case snapshotOnDiskBytes
    case sharedDirectories
    case portForwardingRules
    case events
    case start
    case cancelGuestSetup
    case stop
    case pause
    case resume
    case suspend
    case restart
    case open
    case reveal
    case showInFinder
    case takeSnapshot
    case revertToSnapshot
    case deleteSnapshot
    case renameSnapshot
    case setSnapshotNotes
    case create
    case clone
    case rename
    case delete
    case importVM
    case cancelPreparing
    case awaitPreparing
    case editStorageDisk
    case editRemovableMedia
    case editSharedDirectory
    case editPortForwarding
    case configurationKeys
    case configuration
    case setConfiguration
    case guestAgentDisk
    case quit

    /// What a person calls this verb.
    ///
    /// The raw value is the name a transport parses; this is the name a
    /// sentence puts in front of a user, and no surface should show the other.
    public var displayName: String {
        switch self {
        case .list: "List"
        case .info: "Get Info"
        case .ipAddress: "Get IP Address"
        case .snapshots: "List Snapshots"
        case .snapshotOnDiskBytes: "Get Snapshot Sizes"
        case .sharedDirectories: "List Shared Directories"
        case .portForwardingRules: "List Forwarded Ports"
        case .events: "Watch Events"
        case .start: "Start"
        case .cancelGuestSetup: "Cancel Setup"
        case .stop: "Stop"
        case .pause: "Pause"
        case .resume: "Resume"
        case .suspend: "Suspend"
        case .restart: "Restart"
        case .open: "Open"
        case .reveal: "Reveal"
        case .showInFinder: "Show in Finder"
        case .takeSnapshot: "Take Snapshot"
        case .revertToSnapshot: "Revert to Snapshot"
        case .deleteSnapshot: "Delete Snapshot"
        case .renameSnapshot: "Rename Snapshot"
        case .setSnapshotNotes: "Edit Snapshot Note"
        case .create: "Create"
        case .clone: "Clone"
        case .rename: "Rename"
        case .delete: "Delete"
        case .importVM: "Import"
        case .cancelPreparing: "Cancel"
        case .awaitPreparing: "Wait for Copy"
        case .editStorageDisk: "Edit Storage Disks"
        case .editRemovableMedia: "Edit Removable Media"
        case .editSharedDirectory: "Edit Shared Directories"
        case .editPortForwarding: "Edit Port Forwarding"
        case .configurationKeys: "List Settings Keys"
        case .configuration: "Get Settings"
        case .setConfiguration: "Change Settings"
        case .guestAgentDisk: "Guest Agent Disk"
        case .quit: "Quit"
        }
    }

    /// Whether every state admits the verb, so naming it among the verbs a VM
    /// "accepts now" tells a user nothing.
    ///
    /// The reads, which only answer a question, the reveal that brings a VM in
    /// front of the user whatever state it is in, the Finder reveal and the
    /// settle wait, which address the bundle rather than the guest, and the
    /// quit, which addresses no VM at all.
    ///
    /// The settings write is here too, for a different reason: every state
    /// takes a write of *some* key — the clipboard and Ephemeral Mode flags are
    /// read at moments other than boot — so naming it says nothing about the
    /// key that was refused. ``ConfigurationKeyDescriptor/editableWhileRunning``
    /// is what answers that.
    public var isAdmittedInEveryState: Bool {
        switch self {
        case .list, .info, .ipAddress, .snapshots, .snapshotOnDiskBytes, .sharedDirectories,
            .portForwardingRules, .events, .reveal,
            .showInFinder, .awaitPreparing, .configurationKeys, .configuration, .setConfiguration,
            .quit:
            true
        case .start, .cancelGuestSetup, .stop, .pause, .resume, .suspend, .restart, .open,
            .takeSnapshot, .revertToSnapshot, .deleteSnapshot, .renameSnapshot, .setSnapshotNotes,
            .create, .clone, .rename, .delete, .importVM, .cancelPreparing, .editStorageDisk,
            .editRemovableMedia, .editSharedDirectory, .editPortForwarding, .guestAgentDisk:
            false
        }
    }
}

/// How a stop should reach a powered-off guest.
public enum StopDisposition: String, Codable, Sendable, Hashable, CaseIterable {
    /// Request an ACPI shutdown and let the guest power itself off.
    case graceful
    /// Resume a paused guest first, then request the graceful shutdown it
    /// cannot receive while paused.
    case resumeThenShutDown
    /// Terminate the virtual machine immediately, losing unsaved guest state.
    case force
}

/// What a clone does with the source VM's machine identity.
public enum CloneMachineIdentity: String, Codable, Sendable, Hashable, CaseIterable {
    /// Follow the app's clone preference.
    case followPreference
    /// Mint a fresh identity, so both VMs can run at once.
    case new
    /// Keep the source's identity, so the clone is the same machine to its
    /// guest — and cannot run beside the source.
    case keep
}

/// What two VMs collide on.
public enum ConflictReason: Codable, Sendable, Hashable {
    case machineIdentity
    /// Two VMs would run at once on one network with one address, which both
    /// of them already carry.
    case macAddress
    /// A second VM in the library already holds `address`, whatever state
    /// either is in — the uniqueness every writer of an address preserves.
    /// It travels here because it is the address the caller asked for, which
    /// the VM being refused does not carry: nothing else in the refusal names
    /// which one collided.
    case macAddressInUse(address: String)
}
