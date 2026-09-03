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
    public static let currentProtocolVersion = 1

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

        case start(VMSelector, recovery: Bool)
        case cancelGuestSetup(VMSelector, confirmed: Bool)
        case stop(VMSelector, disposition: StopDisposition, confirmed: Bool)
        case pause(VMSelector)
        case resume(VMSelector)
        case suspend(VMSelector)
        case restart(VMSelector)
        case open(VMSelector)

        case takeSnapshot(VMSelector, name: String, notes: String)
        case revertToSnapshot(
            VMSelector, snapshot: UUID, takingCheckpoint: Bool, confirmed: Bool)
        case deleteSnapshot(VMSelector, snapshot: UUID, confirmed: Bool)
        case renameSnapshot(VMSelector, snapshot: UUID, newName: String)
        case setSnapshotNotes(VMSelector, snapshot: UUID, notes: String)

        case clone(VMSelector, machineIdentity: CloneMachineIdentity)
        case rename(VMSelector, newName: String)
        case delete(VMSelector, permanently: Bool, alsoRemoving: [UUID], confirmed: Bool)
        case importVM(path: String)
        case cancelPreparing(VMSelector, confirmed: Bool)

        case editStorageDisk(VMSelector, StorageDiskEdit)
        case editRemovableMedia(VMSelector, RemovableMediaEdit)
        case editSharedDirectory(VMSelector, SharedDirectoryEdit)
        case guestAgentDisk(VMSelector, GuestAgentDiskEdit)

        /// Which verb this is, for a transport mapping onto its own naming.
        public var verb: VMVerb {
            switch self {
            case .list: .list
            case .info: .info
            case .ipAddress: .ipAddress
            case .snapshots: .snapshots
            case .start: .start
            case .cancelGuestSetup: .cancelGuestSetup
            case .stop: .stop
            case .pause: .pause
            case .resume: .resume
            case .suspend: .suspend
            case .restart: .restart
            case .open: .open
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
            case .editStorageDisk: .editStorageDisk
            case .editRemovableMedia: .editRemovableMedia
            case .editSharedDirectory: .editSharedDirectory
            case .guestAgentDisk: .guestAgentDisk
            }
        }
    }
}
