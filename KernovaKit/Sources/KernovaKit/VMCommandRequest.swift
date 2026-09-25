import Foundation

/// One VM command as it crosses a wire.
///
/// Serialization only: every case maps 1:1 onto a method of the in-process
/// facade, so a transport translates and decides nothing. A door that can call
/// the facade directly — the AppKit UI — never builds one of these.
public struct VMCommandRequest: Codable, Sendable, Hashable {
    /// What this build speaks. A peer answering a different number is talking
    /// about a different vocabulary, so the mismatch is refused rather than
    /// negotiated.
    public static let currentProtocolVersion = 2

    /// The vocabulary this request is written in.
    public var protocolVersion: Int
    /// What is being asked for.
    public var verb: Verb

    /// Wraps one verb for the wire.
    public init(verb: Verb, protocolVersion: Int = VMCommandRequest.currentProtocolVersion) {
        self.protocolVersion = protocolVersion
        self.verb = verb
    }

    /// One call on the facade, with its arguments.
    public enum Verb: Codable, Sendable, Hashable {
        case list
        case info(VMSelector)
        case ipAddress(VMSelector)
        case snapshots(VMSelector)
        /// Bytes each of the VM's snapshots occupies on disk, by snapshot id.
        case snapshotOnDiskBytes(VMSelector)
        /// The folders the VM shares with its guest.
        case sharedDirectories(VMSelector)
        /// The USB accessories this VM's guest currently holds.
        case usbAccessories(VMSelector)
        /// The USB accessories macOS has assigned to Kernova and no guest holds.
        /// Host-scoped: accessories arrive before any VM claims one.
        case availableUSBAccessories
        /// The USB accessories one VM takes back automatically, or every VM's
        /// when no selector is given.
        case usbPairings(VMSelector?)
        /// Stops a VM taking one accessory back, naming it by the durable key
        /// `usbPairings` prints — the device itself is usually not plugged in.
        case forgetUSBPairing(VMSelector, key: String)
        /// Subscribe: a snapshot frame, then one frame per library event.
        case events

        /// A VM that owes its guest a macOS account refuses with
        /// ``CommandErrorDTO/guestAccountPasswordRequired(prompt:)``: the wire
        /// carries no way to answer that, so every out-of-process caller gets
        /// the refusal.
        case start(VMSelector, recovery: Bool)
        case cancelGuestSetup(VMSelector, confirmed: Bool)
        /// `timeout` bounds the wait for the guest to power off, in seconds;
        /// `nil` returns as soon as the guest has been asked to go down.
        case stop(
            VMSelector, disposition: StopDisposition, confirmed: Bool, timeout: TimeInterval?)
        case pause(VMSelector)
        case resume(VMSelector)
        case suspend(VMSelector)
        /// `timeout` bounds the shutdown half, in seconds; a guest still up
        /// when it expires is not started again.
        case restart(VMSelector, timeout: TimeInterval?)
        case open(VMSelector)
        case reveal(VMSelector)
        /// Selects the VM's bundle in the Finder, which is what comes forward.
        case showInFinder(VMSelector)

        case takeSnapshot(VMSelector, name: String, notes: String)
        case revertToSnapshot(
            VMSelector, snapshot: UUID, takingCheckpoint: Bool, confirmed: Bool)
        case deleteSnapshot(VMSelector, snapshot: UUID, confirmed: Bool)
        case renameSnapshot(VMSelector, snapshot: UUID, newName: String)
        case setSnapshotNotes(VMSelector, snapshot: UUID, notes: String)

        case clone(VMSelector, machineIdentity: CloneMachineIdentity)
        case rename(VMSelector, newName: String)
        case delete(VMSelector, permanently: Bool, alsoRemoving: [UUID], confirmed: Bool)
        /// `path` is read as this Mac names it; the app obtains the authority to
        /// read it, which a sandboxed client cannot hand over.
        case importVM(path: String)
        case cancelPreparing(VMSelector, confirmed: Bool)
        /// Waits for a clone or import still copying to settle, answering the
        /// settled row.
        case awaitPreparing(VMSelector)

        case editStorageDisk(VMSelector, StorageDiskEdit)
        case editRemovableMedia(VMSelector, RemovableMediaEdit)
        case editSharedDirectory(VMSelector, SharedDirectoryEdit)
        case editUSBAccessory(VMSelector, USBAccessoryEdit)
        case guestAgentDisk(VMSelector, GuestAgentDiskEdit)

        /// Every configuration key `configuration` and `setConfiguration`
        /// address, in the order they are presented. Addresses no VM: the
        /// keyspace is the same for all of them.
        case configurationKeys
        /// The VM's values for `keys`, or for every key when `keys` is `nil`.
        case configuration(VMSelector, keys: [String]?)
        /// Applies every assignment or none, in the order given, answering the
        /// values the keys ended up holding.
        case setConfiguration(
            VMSelector, assignments: [ConfigurationEntry], confirmed: Bool)

        /// Quits Kernova the way the status item's Quit does, save-suspending
        /// running and paused VMs on the way out.
        case quit

        /// Which verb this is, for a transport mapping onto its own naming.
        public var verb: VMVerb {
            switch self {
            case .list: .list
            case .info: .info
            case .ipAddress: .ipAddress
            case .snapshots: .snapshots
            case .snapshotOnDiskBytes: .snapshotOnDiskBytes
            case .sharedDirectories: .sharedDirectories
            case .usbAccessories: .usbAccessories
            case .availableUSBAccessories: .availableUSBAccessories
            case .usbPairings: .usbPairings
            case .forgetUSBPairing: .forgetUSBPairing
            case .events: .events
            case .start: .start
            case .cancelGuestSetup: .cancelGuestSetup
            case .stop: .stop
            case .pause: .pause
            case .resume: .resume
            case .suspend: .suspend
            case .restart: .restart
            case .open: .open
            case .reveal: .reveal
            case .showInFinder: .showInFinder
            case .takeSnapshot: .takeSnapshot
            case .revertToSnapshot: .revertToSnapshot
            case .deleteSnapshot: .deleteSnapshot
            case .renameSnapshot: .renameSnapshot
            case .setSnapshotNotes: .setSnapshotNotes
            case .clone: .clone
            case .rename: .rename
            case .delete: .delete
            case .importVM: .importVM
            case .cancelPreparing: .cancelPreparing
            case .awaitPreparing: .awaitPreparing
            case .editStorageDisk: .editStorageDisk
            case .editRemovableMedia: .editRemovableMedia
            case .editSharedDirectory: .editSharedDirectory
            case .editUSBAccessory: .editUSBAccessory
            case .guestAgentDisk: .guestAgentDisk
            case .configurationKeys: .configurationKeys
            case .configuration: .configuration
            case .setConfiguration: .setConfiguration
            case .quit: .quit
            }
        }
    }
}
