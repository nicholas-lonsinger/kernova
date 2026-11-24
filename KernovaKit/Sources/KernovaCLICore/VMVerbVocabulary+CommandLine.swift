import ArgumentParser
import Foundation
import KernovaCommandModel

extension VMVerbVocabulary {
    /// How the `kernova` tool names a verb: the words of each subcommand whose
    /// own job it is, the one that performs it or prints what it answers.
    ///
    /// A subcommand that sends a verb only to work out another answer —
    /// `snapshot revert` listing snapshots to resolve a name, `wait` reading
    /// a VM's state and its events — is not named for it.
    static let commandLine = VMVerbVocabulary { verb in
        let paths = subcommands(running: verb).map { KernovaCommand.words(of: $0).joined(separator: " ") }
        return paths.isEmpty ? nil : paths.joined(separator: ", ")
    }

    /// The subcommands whose own job `verb` is, none for a verb no subcommand
    /// runs.
    private static func subcommands(running verb: VMVerb) -> [any ParsableCommand.Type] {
        switch verb {
        case .list: [KernovaCommand.List.self]
        case .groups: [KernovaCommand.Groups.self]
        case .info, .storageDisks: [KernovaCommand.Info.self]
        case .ipAddress: [KernovaCommand.IP.self]
        case .snapshots, .snapshotSizes: [KernovaCommand.Snapshot.List.self]
        case .sharedDirectories: [KernovaCommand.Share.List.self]
        case .usbAccessories, .availableUSBAccessories: [KernovaCommand.USB.List.self]
        case .usbPairings: [KernovaCommand.USB.Rules.self]
        case .forgetUSBPairing: [KernovaCommand.USB.Forget.self]
        case .start: [KernovaCommand.Start.self]
        case .stop: [KernovaCommand.Stop.self]
        case .pause: [KernovaCommand.Pause.self]
        case .resume: [KernovaCommand.Resume.self]
        case .suspend: [KernovaCommand.Suspend.self]
        case .restart: [KernovaCommand.Restart.self]
        case .open: [KernovaCommand.Open.self]
        case .reveal: [KernovaCommand.Reveal.self]
        case .showInFinder: [KernovaCommand.ShowInFinder.self]
        case .takeSnapshot: [KernovaCommand.Snapshot.Take.self]
        case .revertToSnapshot: [KernovaCommand.Snapshot.Revert.self]
        case .deleteSnapshot: [KernovaCommand.Snapshot.Delete.self]
        case .renameSnapshot: [KernovaCommand.Snapshot.Rename.self]
        case .clone: [KernovaCommand.Clone.self]
        case .rename: [KernovaCommand.Rename.self]
        case .delete: [KernovaCommand.Delete.self]
        case .importVM: [KernovaCommand.Import.self]
        case .editSharedDirectory: [KernovaCommand.Share.Add.self, KernovaCommand.Share.Remove.self]
        case .editUSBAccessory: [KernovaCommand.USB.Attach.self, KernovaCommand.USB.Detach.self]
        case .configurationKeys, .configuration: [KernovaCommand.Get.self]
        case .setConfiguration: [KernovaCommand.Set.self]
        case .networks: [KernovaCommand.Network.List.self]
        case .createNetwork: [KernovaCommand.Network.Create.self]
        case .renameNetwork: [KernovaCommand.Network.Rename.self]
        case .deleteNetwork: [KernovaCommand.Network.Delete.self]
        case .quit: [KernovaCommand.Quit.self]
        case .events, .cancelGuestSetup, .setSnapshotNotes, .create, .cancelPreparing,
            .editStorageDisk, .editRemovableMedia, .guestAgentDisk:
            []
        }
    }
}
