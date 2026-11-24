import Foundation

/// One command in the command core's vocabulary.
///
/// Named rather than described so a refusal can list the verbs a VM's current
/// state does allow. The raw value is the name the wire carries; a person reads
/// a verb only through the ``VMVerbVocabulary`` of the surface showing it.
public enum VMVerb: String, Codable, Sendable, Hashable, CaseIterable {
    case list
    case groups
    case info
    case ipAddress
    case snapshots
    case snapshotSizes
    case sharedDirectories
    case storageDisks
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
    case editStorageDisk
    case editRemovableMedia
    case editSharedDirectory
    case editUSBAccessory
    case configurationKeys
    case configuration
    case setConfiguration
    case guestAgentDisk
    case networks
    case createNetwork
    case renameNetwork
    case deleteNetwork
    case quit

    /// Whether every state admits the verb, so naming it among the verbs a VM
    /// "accepts now" tells a user nothing.
    ///
    /// The reads, which only answer a question, the reveal that brings a VM in
    /// front of the user whatever state it is in, the Finder reveal, which
    /// addresses the bundle rather than the guest, and the quit and the
    /// network verbs, which address no VM at all.
    ///
    /// The settings write is here too, for a different reason: every state
    /// takes a write of *some* key — the clipboard and Ephemeral Mode flags are
    /// read at moments other than boot — so naming it says nothing about the
    /// key that was refused. ``ConfigurationKeyDescriptor/editableWhileRunning``
    /// is what answers that.
    public var isAdmittedInEveryState: Bool {
        switch self {
        case .list, .info, .ipAddress, .snapshots, .snapshotSizes, .sharedDirectories, .storageDisks,
            .usbAccessories, .availableUSBAccessories, .usbPairings,
            .forgetUSBPairing, .events, .reveal,
            .showInFinder, .configurationKeys, .configuration, .setConfiguration,
            .groups, .networks, .createNetwork, .renameNetwork, .deleteNetwork, .quit:
            true
        case .start, .cancelGuestSetup, .stop, .pause, .resume, .suspend, .restart, .open,
            .takeSnapshot, .revertToSnapshot, .deleteSnapshot, .renameSnapshot, .setSnapshotNotes,
            .create, .clone, .rename, .delete, .importVM, .cancelPreparing, .editStorageDisk,
            .editRemovableMedia, .editSharedDirectory, .editUSBAccessory,
            .guestAgentDisk:
            false
        }
    }
}
