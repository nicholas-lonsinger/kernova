import Foundation
import KernovaCommandModel

extension VMVerbVocabulary {
    /// How a script names a verb: the term `Kernova.sdef` gives the command
    /// that runs it, or the standard-suite phrase that reaches it.
    ///
    /// A verb no script reaches has none — the `IP address` property included,
    /// which answers from the `virtual machine` read.
    static let appleScript = VMVerbVocabulary { verb in
        switch verb {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        case .pause: "pause"
        case .resume: "resume"
        case .suspend: "suspend"
        case .reveal: "reveal"
        case .list: "get virtual machines"
        case .info: "get virtual machine"
        case .storageDisks: "get storage disks"
        case .setConfiguration: "set"
        case .networks: "get networks"
        case .createNetwork: "make new network"
        case .renameNetwork: "set name of network"
        case .deleteNetwork: "delete network"
        case .snapshots: "get snapshots"
        case .snapshotSizes: "get size of snapshot"
        case .takeSnapshot: "make new snapshot"
        case .revertToSnapshot: "revert to"
        case .deleteSnapshot: "delete snapshot"
        case .renameSnapshot: "set name of snapshot"
        case .setSnapshotNotes: "set notes of snapshot"
        // The standard suite's `quit` is a quit Apple event, which the app
        // classifies by its sender rather than running this verb.
        case .quit, .groups, .ipAddress, .sharedDirectories, .usbAccessories,
            .availableUSBAccessories, .usbPairings, .forgetUSBPairing, .wait, .cancelGuestSetup,
            .open, .showInFinder, .create, .clone, .rename, .delete, .importVM, .cancelPreparing,
            .editStorageDisk, .editRemovableMedia, .editSharedDirectory, .editUSBAccessory,
            .configurationKeys, .configuration, .guestAgentDisk:
            nil
        }
    }
}
