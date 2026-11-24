import AppIntents
import Foundation
import KernovaCommandModel

extension VMVerbVocabulary {
    /// How Shortcuts names a verb: the titles of the actions that run it.
    static let shortcuts = VMVerbVocabulary { verb in
        let titles = actions(running: verb).map { String(localized: $0.title) }
        return titles.isEmpty ? nil : titles.joined(separator: ", ")
    }

    /// The actions that run `verb`, none for a verb no action runs — one
    /// Shortcuts reaches only through an entity's query or property included.
    private static func actions(running verb: VMVerb) -> [any AppIntent.Type] {
        switch verb {
        case .info: [GetVMStateIntent.self]
        case .ipAddress: [GetVMIPAddressIntent.self]
        case .snapshots: [FindSnapshotsIntent.self]
        case .storageDisks: [FindStorageDisksIntent.self]
        case .sharedDirectories: [FindSharedDirectoriesIntent.self]
        case .usbAccessories: [FindAttachedUSBAccessoriesIntent.self]
        case .availableUSBAccessories: [FindAvailableUSBAccessoriesIntent.self]
        case .usbPairings: [FindRememberedUSBAccessoriesIntent.self]
        case .start: [StartVMIntent.self]
        case .cancelGuestSetup: [CancelGuestSetupIntent.self]
        case .stop: [StopVMIntent.self]
        case .pause: [PauseVMIntent.self]
        case .resume: [ResumeVMIntent.self]
        case .suspend: [SuspendVMIntent.self]
        case .restart: [RestartVMIntent.self]
        case .wait: [WaitForVMIntent.self]
        case .reveal: [OpenVMIntent.self]
        case .takeSnapshot: [TakeSnapshotIntent.self]
        case .revertToSnapshot: [RevertToSnapshotIntent.self]
        case .deleteSnapshot: [DeleteSnapshotIntent.self]
        case .renameSnapshot: [RenameSnapshotIntent.self]
        case .setSnapshotNotes: [SetSnapshotNotesIntent.self]
        case .clone: [CloneVMIntent.self]
        case .rename: [RenameVMIntent.self]
        case .delete: [DeleteVMIntent.self]
        case .importVM: [ImportVMIntent.self]
        case .cancelPreparing: [CancelPreparingIntent.self]
        case .editSharedDirectory: [AddSharedDirectoryIntent.self, RemoveSharedDirectoryIntent.self]
        case .editUSBAccessory: [AttachUSBAccessoryIntent.self, DetachUSBAccessoryIntent.self]
        case .forgetUSBPairing: [ForgetUSBAccessoryIntent.self]
        case .configuration: [GetVMSettingIntent.self]
        case .setConfiguration: [SetVMSettingIntent.self]
        case .createNetwork: [CreateNetworkIntent.self]
        case .renameNetwork: [RenameNetworkIntent.self]
        case .deleteNetwork: [DeleteNetworkIntent.self]
        case .quit: [QuitKernovaIntent.self]
        case .list, .groups, .snapshotSizes, .open, .showInFinder, .create, .editStorageDisk,
            .editRemovableMedia, .configurationKeys, .guestAgentDisk, .networks:
            []
        }
    }
}
