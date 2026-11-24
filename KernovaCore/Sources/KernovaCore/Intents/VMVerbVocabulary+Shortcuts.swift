import AppIntents
import Foundation
import KernovaCommandModel

extension VMVerbVocabulary {
    /// How Shortcuts names a verb: the title of the action that runs it.
    static let shortcuts = VMVerbVocabulary { verb in
        action(running: verb).map { String(localized: $0.title) }
    }

    /// The action that runs `verb`, `nil` for a verb no action runs — one
    /// Shortcuts reaches only through an entity's query or property included.
    private static func action(running verb: VMVerb) -> (any AppIntent.Type)? {
        switch verb {
        case .info: GetVMStateIntent.self
        case .ipAddress: GetVMIPAddressIntent.self
        case .snapshots: FindSnapshotsIntent.self
        case .storageDisks: FindStorageDisksIntent.self
        case .start: StartVMIntent.self
        case .cancelGuestSetup: CancelGuestSetupIntent.self
        case .stop: StopVMIntent.self
        case .pause: PauseVMIntent.self
        case .resume: ResumeVMIntent.self
        case .suspend: SuspendVMIntent.self
        case .restart: RestartVMIntent.self
        case .wait: WaitForVMIntent.self
        case .reveal: OpenVMIntent.self
        case .takeSnapshot: TakeSnapshotIntent.self
        case .revertToSnapshot: RevertToSnapshotIntent.self
        case .deleteSnapshot: DeleteSnapshotIntent.self
        case .renameSnapshot: RenameSnapshotIntent.self
        case .setSnapshotNotes: SetSnapshotNotesIntent.self
        case .clone: CloneVMIntent.self
        case .rename: RenameVMIntent.self
        case .delete: DeleteVMIntent.self
        case .importVM: ImportVMIntent.self
        case .cancelPreparing: CancelPreparingIntent.self
        case .setConfiguration: SetVMSettingIntent.self
        case .createNetwork: CreateNetworkIntent.self
        case .renameNetwork: RenameNetworkIntent.self
        case .deleteNetwork: DeleteNetworkIntent.self
        case .quit: QuitKernovaIntent.self
        case .list, .groups, .snapshotSizes, .sharedDirectories, .usbAccessories,
            .availableUSBAccessories, .usbPairings, .forgetUSBPairing, .open, .showInFinder,
            .create, .editStorageDisk, .editRemovableMedia, .editSharedDirectory, .editUSBAccessory,
            .configurationKeys, .configuration, .guestAgentDisk, .networks:
            nil
        }
    }
}
