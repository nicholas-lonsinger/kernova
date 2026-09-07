import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova get <vm> [key ...]` — what a virtual machine's settings hold.
    public struct Get: VerbCommand {
        /// What `kernova get --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print a virtual machine's settings.",
            discussion: "Naming no key prints every setting the guest has, in the order --keys "
                + "lists them; naming keys prints those, in the order asked. A value is written "
                + "the way `set` takes it back, so a line of output is a line of input. --keys "
                + "prints the settings themselves rather than one virtual machine's values, and "
                + "names no virtual machine.")

        /// Which virtual machine, by name or identifier; absent only with
        /// `--keys`.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String?

        /// Which settings to print; none prints every one the guest has.
        @Argument(
            help: "The settings to print; all of them when none is named.",
            completion: CompletionSource.configurationKey)
        public var keys: [String] = []

        /// List the settings themselves rather than one virtual machine's
        /// values.
        @Flag(
            name: .customLong("keys"),
            help: "List every setting, what it takes, and whether a running guest accepts it.")
        public var listingKeys = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// What a `get` naming no virtual machine is missing.
        ///
        /// One string for both the refusal and the check that raises it, in
        /// ArgumentParser's own words for a positional it did not receive.
        static let missingVM = "Missing expected argument '<vm>'."

        /// Refuses a line that names a virtual machine the keyspace listing has
        /// no use for, and one that names none where a value read needs it.
        public func validate() throws {
            guard listingKeys else {
                guard vm != nil else { throw ValidationError(Self.missingVM) }
                return
            }
            guard vm == nil, keys.isEmpty else {
                throw ValidationError(
                    "--keys lists the settings themselves, which are the same for every virtual "
                        + "machine, so it takes no arguments.")
            }
        }

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            guard !listingKeys else { return .configurationKeys }
            guard let vm else { throw CLIFailure(.usage, Self.missingVM) }
            return .configuration(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                keys: keys.isEmpty ? nil : keys)
        }

        /// Reads the settings and writes them.
        public func run() throws {
            try ConfigurationOutput.write(try answer(), options: options)
        }
    }

    /// `kernova set <vm> <key=value> ...` — change what a virtual machine's
    /// settings hold.
    public struct Set: VerbCommand {
        /// What `kernova set --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Change a virtual machine's settings.",
            discussion: "Each argument is one key=value assignment; `get --keys` lists what a "
                + "key may be and what it takes. Every assignment lands or none does, so a line "
                + "naming one setting the virtual machine will not take right now changes "
                + "nothing at all. Prints the settings as they ended up, the way `get` prints "
                + "them.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The changes to apply, each written `key=value`; at least one.
        @Argument(
            help: "One or more key=value assignments.",
            completion: CompletionSource.configurationAssignment)
        public var assignments: [String]

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .setConfiguration(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                assignments: try Self.entries(from: assignments), confirmed: options.yes)
        }

        /// Applies the assignments and writes what the settings ended up
        /// holding.
        public func run() throws {
            try ConfigurationOutput.write(try answer(), options: options)
        }

        /// The assignments `arguments` spell out.
        ///
        /// Split at the first `=`, so a value carrying one of its own arrives
        /// whole. An empty value is a value: it is how the settings that take a
        /// spelled-out name are cleared.
        static func entries(from arguments: [String]) throws -> [ConfigurationEntry] {
            try arguments.map { argument in
                guard let separator = argument.firstIndex(of: "=") else {
                    throw CLIFailure(
                        .usage,
                        "\u{201C}\(argument)\u{201D} is not a key=value assignment.")
                }
                let key = String(argument[argument.startIndex..<separator])
                guard !key.isEmpty else {
                    throw CLIFailure(
                        .usage,
                        "\u{201C}\(argument)\u{201D} names no setting before its =.")
                }
                return ConfigurationEntry(
                    key: key, value: String(argument[argument.index(after: separator)...]))
            }
        }
    }

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

    /// `kernova forward` — a virtual machine's host→guest port mappings.
    public struct Forward: ParsableCommand {
        /// What `kernova forward --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "forward",
            abstract: "Work with a virtual machine's forwarded ports.",
            discussion: "Each mapping is written <host-port>:<guest-port>, and covers TCP unless "
                + "--udp says otherwise. A host port is claimed across every virtual machine on "
                + "the network, so one another rule already forwards is refused.",
            subcommands: [Add.self, Remove.self])

        /// Creates the parent command; a bare `kernova forward` prints this
        /// help.
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

extension KernovaCommand.Forward {
    /// `kernova forward add <vm> <host-port>:<guest-port>` — publish a guest
    /// port on this Mac.
    public struct Add: VerbCommand {
        /// What `kernova forward add --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Forward a host port to a guest port.",
            discussion: "The rule is carried by the network the virtual machine is joined to, "
                + "so it takes effect the next time that network is declared.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The mapping to add, written `<host-port>:<guest-port>`.
        @Argument(help: "The mapping to add, as <host-port>:<guest-port>.")
        public var mapping: String

        /// Forward UDP rather than TCP.
        @Flag(name: .long, help: "Forward UDP rather than TCP.")
        public var udp = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .editPortForwarding(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .add(rule: try PortMapping.rule(from: mapping, transport: udp ? .udp : .tcp)))
        }

        /// Adds the rule.
        public func run() throws {
            try perform()
        }
    }

    /// `kernova forward remove <vm> <host-port>:<guest-port>` — stop
    /// publishing one.
    public struct Remove: VerbCommand {
        /// What `kernova forward remove --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Stop forwarding a host port to a guest port.",
            discussion: "A network carries one rule per transport and host port, so the host "
                + "half of the mapping is what names the rule to drop. One the virtual machine "
                + "does not carry exits 2.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The mapping to drop, written `<host-port>:<guest-port>`.
        @Argument(help: "The mapping to drop, as <host-port>:<guest-port>.")
        public var mapping: String

        /// Drop a UDP rule rather than a TCP one.
        @Flag(name: .long, help: "Drop the UDP rule rather than the TCP one.")
        public var udp = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .editPortForwarding(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .remove(
                    claim: try PortMapping.rule(from: mapping, transport: udp ? .udp : .tcp)
                        .hostClaim))
        }

        /// Drops the rule.
        public func run() throws {
            try perform()
        }
    }
}

/// How `get` and `set` write the answer they share.
enum ConfigurationOutput {
    /// Writes whichever settings answer `result` carries.
    ///
    /// - Throws: ``CLIFailure`` when the answer is neither, which means the app
    ///   answered a different verb than the one asked.
    static func write(_ result: VMCommandResponse.Result, options: GlobalOptions) throws {
        switch result {
        case .configuration(let entries):
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(entries)
                    : TableRenderer.render(entries, quiet: options.quiet))
        case .configurationKeys(let descriptors):
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(descriptors)
                    : TableRenderer.render(descriptors, quiet: options.quiet))
        default:
            throw result.unexpectedAnswer
        }
    }
}

/// How the tool reads a `<host-port>:<guest-port>` argument.
enum PortMapping {
    /// The rule `text` names on `transport`.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/usage`` when `text` is not a
    ///   pair of ports a service can answer on.
    static func rule(
        from text: String, transport: PortForwardingTransport
    ) throws -> PortForwardingRule {
        let halves = text.split(separator: ":", omittingEmptySubsequences: false)
        guard halves.count == 2 else {
            throw CLIFailure(
                .usage,
                "\u{201C}\(text)\u{201D} is not a <host-port>:<guest-port> mapping.")
        }
        return PortForwardingRule(
            transport: transport,
            hostPort: try port(String(halves[0]), of: text),
            guestPort: try port(String(halves[1]), of: text))
    }

    /// One half of a mapping as a port number.
    ///
    /// Refuses rather than clamping, and refuses port 0 with everything else
    /// outside the range: it addresses no service, so a rule naming it would
    /// forward nothing.
    private static func port(_ text: String, of mapping: String) throws -> UInt16 {
        let range = PortForwardingRule.portRange
        guard let value = Int(text), range.contains(value) else {
            throw CLIFailure(
                .usage,
                "\u{201C}\(mapping)\u{201D} names \u{201C}\(text)\u{201D}, which is not a port "
                    + "between \(range.lowerBound) and \(range.upperBound).")
        }
        return UInt16(value)
    }
}
