import ArgumentParser
import Foundation
import KernovaCommandModel

extension VMVerbVocabulary {
    /// How the `kernova` tool names a verb: the words, under `kernova`, of
    /// each subcommand that sends it.
    static let commandLine = VMVerbVocabulary { verb in
        let paths = subcommands(sending: verb).compactMap { subcommand in
            let path = KernovaCommand.path(to: subcommand)
            if path == nil { assertionFailure("\(subcommand) is not a subcommand of kernova") }
            return path
        }
        return paths.isEmpty ? nil : paths.joined(separator: ", ")
    }

    /// The subcommands that send `verb`, none for a verb the tool does not
    /// send.
    private static func subcommands(sending verb: VMVerb) -> [any ParsableCommand.Type] {
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
        case .events: [KernovaCommand.Wait.self]
        case .start: [KernovaCommand.Start.self]
        case .stop: [KernovaCommand.Stop.self]
        case .pause: [KernovaCommand.Pause.self]
        case .resume: [KernovaCommand.Resume.self]
        case .suspend: [KernovaCommand.Suspend.self]
        case .restart: [KernovaCommand.Restart.self]
        case .open: [KernovaCommand.Open.self]
        case .showInFinder: [KernovaCommand.Reveal.self]
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
        case .cancelGuestSetup, .reveal, .setSnapshotNotes, .create, .cancelPreparing,
            .editStorageDisk, .editRemovableMedia, .guestAgentDisk:
            []
        }
    }
}

extension KernovaCommand {
    /// The words that run `command` under `kernova` — `snapshot take` for
    /// ``Snapshot/Take`` — or `nil` for a command the tree does not hold.
    static func path(to command: any ParsableCommand.Type) -> String? {
        path(to: command, among: configuration.subcommands)?.joined(separator: " ")
    }

    /// The names leading from `subcommands` to `command`, depth first.
    private static func path(
        to command: any ParsableCommand.Type, among subcommands: [any ParsableCommand.Type]
    ) -> [String]? {
        for subcommand in subcommands {
            guard let name = subcommand.configuration.commandName else {
                assertionFailure("\(subcommand) names no command")
                continue
            }
            if ObjectIdentifier(subcommand) == ObjectIdentifier(command) { return [name] }
            if let rest = path(to: command, among: subcommand.configuration.subcommands) {
                return [name] + rest
            }
        }
        return nil
    }
}
