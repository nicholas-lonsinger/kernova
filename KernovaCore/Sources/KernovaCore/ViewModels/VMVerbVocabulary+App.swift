import Foundation
import KernovaCommandModel

extension VMVerbVocabulary {
    /// How the app's own windows and alerts name a verb: the words the app
    /// gives the command that runs it, without the ellipsis of a menu item
    /// that asks for more.
    ///
    /// A read the app shows rather than runs as a command, and a verb only
    /// another door offers, have none. A `kernova:` link's refusal is shown
    /// in an app alert, so it is worded here too.
    package static let app = VMVerbVocabulary { verb in
        switch verb {
        case .forgetUSBPairing: "Forget USB Accessory"
        case .start: "Start"
        case .cancelGuestSetup: "Cancel Setup"
        case .stop: "Stop"
        case .pause: "Pause"
        case .resume: "Resume"
        case .suspend: "Suspend"
        case .restart: "Restart"
        case .showInFinder: "Show in Finder"
        case .takeSnapshot: "Take Snapshot"
        case .revertToSnapshot: "Revert to Snapshot"
        case .deleteSnapshot: "Delete Snapshot"
        case .renameSnapshot: "Rename Snapshot"
        case .setSnapshotNotes: "Edit Snapshot Note"
        case .create: "New Virtual Machine"
        case .clone: "Clone"
        case .rename: "Rename"
        case .delete: "Move to Trash"
        case .importVM: "Import"
        case .cancelPreparing: "Cancel"
        case .editStorageDisk: "Edit Storage Disks"
        case .editRemovableMedia: "Edit Removable Media"
        case .editSharedDirectory: "Edit Shared Directories"
        case .editUSBAccessory: "Edit USB Accessories"
        case .setConfiguration: "Change Settings"
        case .guestAgentDisk: "Guest Agent Disk"
        case .createNetwork: "Create Network"
        case .renameNetwork: "Rename Network"
        case .deleteNetwork: "Delete Network"
        case .quit: "Quit Kernova"
        case .list, .groups, .info, .ipAddress, .snapshots, .snapshotSizes, .sharedDirectories,
            .storageDisks, .usbAccessories, .availableUSBAccessories, .usbPairings, .events, .open,
            .reveal, .configurationKeys, .configuration, .networks:
            nil
        }
    }
}
