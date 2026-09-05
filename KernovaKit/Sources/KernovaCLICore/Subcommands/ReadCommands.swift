import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova list` — every virtual machine, in the order the sidebar shows.
    public struct List: ParsableCommand {
        /// What `kernova list --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List every virtual machine.")

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Reads the library and writes it.
        public func run() throws {
            let client = try CommandConnection.open(options)
            defer { client.close() }
            let answer = try client.send(.list).payload()
            guard case .summaries(let rows) = answer else { throw answer.unexpectedAnswer }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(rows)
                    : TableRenderer.render(rows, quiet: options.quiet))
        }
    }

    /// `kernova info <vm>` — everything one virtual machine reports.
    public struct Info: ParsableCommand {
        /// What `kernova info --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Describe one virtual machine.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Reads the VM and writes it.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(options)
            defer { client.close() }
            let answer = try client.send(.info(selector)).payload()
            guard case .info(let info) = answer else { throw answer.unexpectedAnswer }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(info)
                    : TableRenderer.render(info, quiet: options.quiet))
        }
    }

    /// `kernova ip <vm>` — the guest's address, or why there isn't one.
    public struct IP: ParsableCommand {
        /// What `kernova ip --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "ip",
            abstract: "Print a guest's IP address.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Reads the address and writes it, or refuses with what stands in its
        /// way.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(options)
            defer { client.close() }
            let answer = try client.send(.ipAddress(selector)).payload()
            guard case .ipAddress(let address) = answer else { throw answer.unexpectedAnswer }
            if options.format == .json {
                Console.out(try JSONRenderer.render(address))
                return
            }
            Console.out(try KernovaCommand.IP.line(for: address, vm: vm))
        }

        /// The one line an address prints, or the refusal it stands for.
        ///
        /// Only `.reserved` is an address. The other three are answers to a
        /// different question — there will never be one, somebody else assigns
        /// it, not yet — so each refuses rather than printing prose a script
        /// would parse as an address.
        static func line(for address: GuestIPAddress, vm: String) throws -> String {
            switch address {
            case .reserved(let value):
                return value
            case .pending:
                throw CLIFailure(
                    .refusedByState,
                    "\u{201C}\(vm)\u{201D} has a reservation, but its network has not published "
                        + "an address yet.")
            case .externallyAssigned:
                throw CLIFailure(
                    .refusedByState,
                    "\u{201C}\(vm)\u{201D} is bridged, so your network assigns its address and "
                        + "Kernova cannot state it.")
            case .unavailable:
                throw CLIFailure(
                    .refusedByState,
                    "Nothing assigns \u{201C}\(vm)\u{201D} an address Kernova can state.")
            }
        }
    }

    /// `kernova version` — which tool this is.
    public struct Version: ParsableCommand {
        /// What `kernova version --help` says.
        ///
        /// It contacts nothing: the tool and the app it was installed from ship
        /// together, so this answers whether the tool works at all, without
        /// launching anything.
        public static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Print this tool's version.")

        /// Creates the subcommand.
        public init() {}

        /// Writes the version.
        public func run() throws {
            Console.out(KernovaCommand.toolVersion)
        }
    }
}
