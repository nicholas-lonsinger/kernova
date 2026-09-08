import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova share` — the folders a virtual machine shares with its guest.
    public struct Share: ParsableCommand {
        /// What `kernova share --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "share",
            abstract: "Work with the folders a virtual machine shares with its guest.",
            discussion: "A share is named by its folder's path, which is also what the guest "
                + "mounts it by. A relative path is read against the directory you type it in.",
            subcommands: [Add.self, Remove.self])

        /// Creates the parent command; a bare `kernova share` prints this help.
        public init() {}
    }
}

extension KernovaCommand.Share {
    /// `kernova share add <vm> <path>` — put a folder in front of the guest.
    public struct Add: VerbCommand {
        /// What `kernova share add --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Share a folder with a virtual machine's guest.",
            discussion: "Kernova asks for permission on this Mac's screen when the folder is "
                + "not one it may already read, and this command waits for the answer. A folder "
                + "the virtual machine already shares is left as it is.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The folder to share, as this Mac names it.
        @Argument(help: "The path of the folder to share.", completion: .directory)
        public var path: String

        /// Mount the folder read-only in the guest.
        @Flag(name: .long, help: "Let the guest read the folder but not write to it.")
        public var readOnly = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .editSharedDirectory(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .add(path: PathParsing.wirePath(for: path), readOnly: readOnly))
        }

        /// Shares the folder.
        public func run() throws {
            try perform()
        }
    }

    /// `kernova share remove <vm> <path>` — take a folder back.
    public struct Remove: VerbCommand {
        /// What `kernova share remove --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Stop sharing a folder with a virtual machine's guest.",
            discussion: "The folder itself is never touched, and a path the virtual machine "
                + "does not share exits 2.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The folder to stop sharing, as this Mac names it.
        @Argument(help: "The path of the folder to stop sharing.", completion: .directory)
        public var path: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .editSharedDirectory(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .removePath(path: PathParsing.wirePath(for: path)))
        }

        /// Drops the share.
        public func run() throws {
            try perform()
        }
    }
}
