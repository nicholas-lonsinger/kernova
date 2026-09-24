import Foundation

/// How a caller names one virtual machine.
///
/// Display names are not unique, so a name that matches more than one VM
/// resolves to an ambiguity refusal carrying every candidate rather than to a
/// guess.
public enum VMSelector: Codable, Sendable, Hashable {
    /// The VM's stable identifier.
    case id(UUID)
    /// The VM's display name, matched whole and without regard to case.
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
    case usbAccessories
    case availableUSBAccessories
    case usbPairings
    case forgetUSBPairing
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
    case editUSBAccessory
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
        case .usbAccessories: "List USB Accessories"
        case .availableUSBAccessories: "List Available USB Accessories"
        case .usbPairings: "List Remembered USB Accessories"
        case .forgetUSBPairing: "Forget USB Accessory"
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
        case .editUSBAccessory: "Edit USB Accessories"
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
            .usbAccessories, .availableUSBAccessories, .usbPairings,
            .forgetUSBPairing, .events, .reveal,
            .showInFinder, .awaitPreparing, .configurationKeys, .configuration, .setConfiguration,
            .quit:
            true
        case .start, .cancelGuestSetup, .stop, .pause, .resume, .suspend, .restart, .open,
            .takeSnapshot, .revertToSnapshot, .deleteSnapshot, .renameSnapshot, .setSnapshotNotes,
            .create, .clone, .rename, .delete, .importVM, .cancelPreparing, .editStorageDisk,
            .editRemovableMedia, .editSharedDirectory, .editUSBAccessory,
            .guestAgentDisk:
            false
        }
    }

    /// Whether performing this verb puts something on screen.
    ///
    /// A door outside the app brings the app forward before it does — a window
    /// ordered front behind the terminal, script or link that asked for it has
    /// not answered anybody. Only the two verbs whose whole purpose is to show
    /// something qualify: bringing a guest up is not a request to look at it,
    /// and `open` is the verb that asks for that.
    public var surfacesInterface: Bool {
        switch self {
        case .open, .reveal:
            true
        case .list, .info, .ipAddress, .snapshots, .snapshotOnDiskBytes, .sharedDirectories,
            .usbAccessories, .availableUSBAccessories, .usbPairings,
            .forgetUSBPairing, .events, .start, .cancelGuestSetup, .stop, .pause, .resume,
            .suspend, .restart, .showInFinder, .takeSnapshot, .revertToSnapshot, .deleteSnapshot,
            .renameSnapshot, .setSnapshotNotes, .create, .clone, .rename, .delete, .importVM,
            .cancelPreparing, .awaitPreparing, .editStorageDisk, .editRemovableMedia,
            .editSharedDirectory, .editUSBAccessory, .configurationKeys,
            .configuration, .setConfiguration, .guestAgentDisk, .quit:
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
    /// Other VMs in the library already hold `address`, whatever state any is
    /// in — the uniqueness every writer of an address preserves. It travels
    /// here because it is the address the caller asked for, which the VM being
    /// refused does not carry: nothing else in the refusal names which one
    /// collided.
    ///
    /// `holding` is how the refusal's other VM holds it, and `otherHolders`
    /// every further VM that does, in library order.
    case macAddressInUse(
        address: String, holding: MACAddressHolding, otherHolders: [MACAddressHolder])
}

/// How one VM holds a MAC address: in its configuration, in snapshots taken
/// with it — each of which a revert puts back on it — or both.
public enum MACAddressHolding: Codable, Sendable, Hashable {
    case configuration
    case snapshots(HeldSnapshots)
    case configurationAndSnapshots(HeldSnapshots)

    /// The holding `configured` and `snapshots` describe, or `nil` when they
    /// describe none.
    public init?(configured: Bool, snapshots: [HeldSnapshot]) {
        switch (configured, HeldSnapshots(snapshots)) {
        case (true, nil): self = .configuration
        case (false, let held?): self = .snapshots(held)
        case (true, let held?): self = .configurationAndSnapshots(held)
        case (false, nil): return nil
        }
    }
}

/// The snapshots of one VM taken with a MAC address — at least one.
public struct HeldSnapshots: Codable, Sendable, Hashable {
    /// The first of them, in the order they were taken.
    public let first: HeldSnapshot
    /// The others, in the order they were taken.
    public let rest: [HeldSnapshot]

    /// `first`, then `rest`.
    public init(_ first: HeldSnapshot, _ rest: [HeldSnapshot] = []) {
        self.first = first
        self.rest = rest
    }

    /// `snapshots`, or `nil` when there are none.
    public init?(_ snapshots: [HeldSnapshot]) {
        guard let first = snapshots.first else { return nil }
        self.init(first, Array(snapshots.dropFirst()))
    }

    /// Every one of them, in the order they were taken.
    public var all: [HeldSnapshot] { [first] + rest }
}

/// One snapshot taken with a MAC address.
public struct HeldSnapshot: Codable, Sendable, Hashable {
    /// What the user called it.
    public let name: String
    /// Whether it is its VM's Ephemeral Mode baseline, which cannot be
    /// deleted while the mode is on.
    public let isEphemeralBaseline: Bool

    /// Names one snapshot.
    public init(name: String, isEphemeralBaseline: Bool) {
        self.name = name
        self.isEphemeralBaseline = isEphemeralBaseline
    }
}

/// A VM holding a MAC address beyond the one a refusal names, and how.
public struct MACAddressHolder: Codable, Sendable, Hashable {
    /// The VM's display name.
    public let name: String
    /// How it holds the address.
    public let holding: MACAddressHolding

    /// Names one holder.
    public init(name: String, holding: MACAddressHolding) {
        self.name = name
        self.holding = holding
    }
}
