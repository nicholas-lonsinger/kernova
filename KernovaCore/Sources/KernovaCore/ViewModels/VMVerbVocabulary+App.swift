import Foundation
import KernovaCommandModel

extension VMVerbVocabulary {
    /// How the app's own windows and alerts name a verb: the base title of
    /// the Virtual Machine or File menu command that runs it
    /// (``AppCommandTitle``) — the base, because the menu retitles the start
    /// and stop slots for a VM whose state calls for another word. Clone,
    /// which the menu offers as one command per outcome, is named by the word
    /// both open with, the toolbar's title for it.
    ///
    /// A verb the app runs only through controls titled in context — a
    /// snapshot row's actions, a settings panel's buttons, the USB Device
    /// menu, the guest agent disk item, the setup view's Cancel — has none,
    /// and so does one the app's own controls never run. A `kernova:` link's
    /// refusal is shown in an app alert, so it is worded here too.
    package static let app = VMVerbVocabulary { verb in
        switch verb {
        case .create: AppCommandTitle.newVirtualMachine
        case .start: AppCommandTitle.start
        case .pause: AppCommandTitle.pause
        case .resume: AppCommandTitle.resume
        case .stop: AppCommandTitle.stop
        case .restart: AppCommandTitle.restart
        case .suspend: AppCommandTitle.suspend
        case .takeSnapshot: AppCommandTitle.takeSnapshot
        case .revertToSnapshot: AppCommandTitle.revertToSnapshot
        case .rename: AppCommandTitle.rename
        case .clone: AppCommandTitle.clone
        case .showInFinder: AppCommandTitle.showInFinder
        case .delete: AppCommandTitle.moveToTrash
        case .list, .groups, .info, .ipAddress, .snapshots, .snapshotSizes, .sharedDirectories,
            .storageDisks, .usbAccessories, .availableUSBAccessories, .usbPairings, .forgetUSBPairing,
            .events, .cancelGuestSetup, .open, .reveal, .deleteSnapshot, .renameSnapshot,
            .setSnapshotNotes, .importVM, .cancelPreparing, .editStorageDisk, .editRemovableMedia,
            .editSharedDirectory, .editUSBAccessory, .configurationKeys, .configuration,
            .setConfiguration, .guestAgentDisk, .networks, .createNetwork, .renameNetwork,
            .deleteNetwork, .quit:
            nil
        }
    }
}
