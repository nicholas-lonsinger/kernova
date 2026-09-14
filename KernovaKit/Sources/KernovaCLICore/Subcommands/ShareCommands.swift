import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova share` — the folders a virtual machine shares with its guest.
    struct Share: ParsableCommand {
        /// What `kernova share --help` says.
        static let configuration = CommandConfiguration(
            commandName: "share",
            abstract: "Work with the folders a virtual machine shares with its guest.",
            discussion: "A share is named by its folder's path, which is also what the guest "
                + "mounts it by. A relative path is read against the directory you type it in.",
            subcommands: [List.self, Add.self, Remove.self])
    }
}

extension KernovaCommand.Share {
    /// `kernova share list <vm>` — every folder the guest is offered.
    struct List: VerbCommand {
        /// What `kernova share list --help` says.
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the folders a virtual machine shares with its guest.",
            discussion: "Each folder prints by the path `share remove` takes back, with whether "
                + "the guest may write to it. The folders themselves are not opened, so one that "
                + "has moved is listed the way the virtual machine carries it.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .sharedDirectories(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Reads the shares and writes them.
        func run() throws {
            let answered = try answer()
            guard case .sharedDirectories(let shares) = answered else {
                throw answered.unexpectedAnswer
            }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(shares)
                    : TableRenderer.render(shares, quiet: options.quiet))
        }
    }

    /// `kernova share add <vm> <path>` — put a folder in front of the guest.
    struct Add: VerbCommand {
        /// What `kernova share add --help` says.
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Share a folder with a virtual machine's guest.",
            discussion: "Kernova asks for permission on this Mac's screen when the folder is "
                + "not one it may already read, and this command waits for the answer. A folder "
                + "the virtual machine already shares is left as it is.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The folder to share, as this Mac names it.
        @Argument(help: "The path of the folder to share.", completion: .directory)
        var path: String

        /// Mount the folder read-only in the guest.
        @Flag(name: .long, help: "Let the guest read the folder but not write to it.")
        var readOnly = false

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .editSharedDirectory(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .add(path: PathParsing.wirePath(for: path), readOnly: readOnly))
        }

        /// Shares the folder.
        func run() throws {
            try perform()
        }
    }

    /// `kernova share remove <vm> <path>` — take a folder back.
    struct Remove: VerbCommand, VMScopedCommandLine {
        /// What `kernova share remove --help` says.
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Stop sharing a folder with a virtual machine's guest.",
            discussion: "The folder itself is never touched, and a path the virtual machine "
                + "does not share exits 2.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The folder to stop sharing, as this Mac names it.
        @Argument(
            help: "The path of the folder to stop sharing.",
            completion: CompletionSource.sharedDirectory)
        var path: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .editSharedDirectory(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .removePath(path: PathParsing.wirePath(for: path)))
        }

        /// Drops the share.
        func run() throws {
            try perform()
        }
    }
}
