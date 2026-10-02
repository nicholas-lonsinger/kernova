import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova network` — the library's named networks.
    struct Network: ParsableCommand {
        /// What `kernova network --help` says.
        static let configuration = CommandConfiguration(
            commandName: "network",
            abstract: "Work with the library's named networks.",
            discussion: "The virtual machines on a named network reach each other and no other "
                + "guest. A virtual machine joins one by setting network.membership to its name "
                + "or identifier, and runs in the network's kind, which is fixed when the network "
                + "is created. Every verb here names a network by name or identifier.",
            subcommands: [List.self, Create.self, Rename.self, Delete.self])
    }
}

extension KernovaCommand.Network {
    /// `kernova network list` — every named network and the VMs on it.
    struct List: VerbCommand {
        /// What `kernova network list --help` says.
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the library's named networks.",
            discussion: "Each row names the virtual machines on the network. KIND is the "
                + "network.mode every one of them runs in.")

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb { .networks }

        /// Reads the networks and writes them.
        func run() throws {
            let answered = try answer()
            guard case .networks(let networks) = answered else { throw answered.unexpectedAnswer }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(networks)
                    : TableRenderer.render(networks, quiet: options.quiet))
        }
    }

    /// `kernova network create <name> [--kind <kind>]` — list a new network.
    struct Create: VerbCommand {
        /// What `kernova network create --help` says.
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Create a named network.",
            discussion: "No virtual machine is on it yet; set a virtual machine's "
                + "network.membership to its name to move it there. Prints the new network as "
                + "one row of `network list`.")

        /// What to call it.
        @Argument(help: "The network's name, unique in the library.")
        var name: String

        /// The mode every VM on it runs in.
        @Option(name: .long, help: "The network.mode every virtual machine on it runs in.")
        var kind: NetworkKind = .shared

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb { .createNetwork(name: name, kind: kind) }

        /// Creates the network and writes the row it produced.
        func run() throws {
            let answered = try answer()
            guard case .network(let created) = answered else { throw answered.unexpectedAnswer }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(created)
                    : TableRenderer.render([created], quiet: options.quiet))
        }
    }

    /// `kernova network rename <network> <new-name>` — relabel one.
    struct Rename: VerbCommand {
        /// What `kernova network rename --help` says.
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename a named network.",
            discussion: "The virtual machines on it stay on it: they name it by identifier.")

        /// Which network, by name or identifier.
        @Argument(help: "The network's name or identifier.", completion: CompletionSource.network)
        var network: String

        /// What to call it instead.
        @Argument(help: "The new network name, unique in the library.")
        var newName: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .renameNetwork(network: network, newName: newName)
        }

        /// Renames the network.
        func run() throws {
            try perform()
        }
    }

    /// `kernova network delete <network>` — stop listing one.
    struct Delete: VerbCommand {
        /// What `kernova network delete --help` says.
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a named network.",
            discussion: "Each virtual machine on it moves to a network of its own first. A "
                + "virtual machine that cannot move refuses the whole delete, and nothing moves.")

        /// Which network, by name or identifier.
        @Argument(help: "The network's name or identifier.", completion: CompletionSource.network)
        var network: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb { .deleteNetwork(network: network) }

        /// Deletes the network.
        func run() throws {
            try perform()
        }
    }
}

extension NetworkKind: ExpressibleByArgument {}
