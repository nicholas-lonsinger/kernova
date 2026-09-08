import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova list` — every virtual machine, in the order the sidebar shows.
    public struct List: VerbCommand {
        /// What `kernova list --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List every virtual machine.")

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .list
        }

        /// Reads the library and writes it.
        public func run() throws {
            let result = try answer()
            guard case .summaries(let rows) = result else { throw result.unexpectedAnswer }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(rows)
                    : TableRenderer.render(rows, quiet: options.quiet))
        }
    }

    /// `kernova info <vm>` — everything one virtual machine reports.
    public struct Info: VerbCommand {
        /// What `kernova info --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Describe one virtual machine.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .info(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Reads the VM and writes it.
        public func run() throws {
            let result = try answer()
            guard case .info(let info) = result else { throw result.unexpectedAnswer }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(info)
                    : TableRenderer.render(info, quiet: options.quiet))
        }
    }

    /// `kernova ip <vm>` — the guest's address, or why there isn't one.
    public struct IP: VerbCommand {
        /// What `kernova ip --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "ip",
            abstract: "Print a guest's IP address.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// Keep asking until the guest has an address.
        @Flag(name: .long, help: "Keep asking until the guest has an address.")
        public var wait = false

        /// How long `--wait` waits before giving up.
        @Option(name: .long, help: "Seconds to wait before giving up, with --wait.")
        public var timeout: Double = 300

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Refuses a deadline that names no wait.
        public func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .ipAddress(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Reads the address and writes it, or refuses with what stands in its
        /// way.
        public func run() throws {
            let address = try resolve()
            // Classified before either renderer runs, so both formats exit the
            // same way: an answer that is not an address refuses whether or not
            // JSON could have described it.
            let line = try KernovaCommand.IP.line(for: address, vm: vm)
            Console.out(
                options.format == .json ? try JSONRenderer.render(address) : line)
        }

        /// The guest's address, waiting for one only where waiting can help.
        ///
        /// `--wait` polls: a reserved address is published by the vmnet layer,
        /// which emits no library event, so there is no signal to await. Only
        /// `pending` is worth waiting on — `unavailable` and
        /// `externallyAssigned` are answers rather than delays, and polling
        /// them to the deadline would turn a clear refusal into a long silence.
        private func resolve() throws -> GuestIPAddress {
            let request = try verb()
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
                let answer = try client.send(request).payload()
                client.close()
                guard case .ipAddress(let address) = answer else { throw answer.unexpectedAnswer }
                guard wait, case .pending = address else { return address }
                guard Date() < deadline else {
                    throw CLIFailure(
                        .timedOut,
                        "\u{201C}\(vm)\u{201D} had no address within \(Int(timeout)) seconds.")
                }
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        }

        /// How often `--wait` asks again.
        ///
        /// A reservation lands when the network materializes, a one-off at VM
        /// start rather than something that drifts, so a slow cadence costs a
        /// script nothing.
        private static let pollInterval: TimeInterval = 1

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
