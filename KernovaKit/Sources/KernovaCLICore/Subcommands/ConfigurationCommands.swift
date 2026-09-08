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
