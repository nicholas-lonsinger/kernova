import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova list` — every virtual machine, in the order the sidebar shows.
    struct List: VerbCommand {
        /// What `kernova list --help` says.
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List every virtual machine.")

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .list
        }

        /// Reads the library and writes it.
        func run() throws {
            let result = try answer()
            guard case .summaries(let rows) = result else { throw result.unexpectedAnswer }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(rows)
                    : TableRenderer.render(rows, quiet: options.quiet))
        }
    }

    /// `kernova info <vm>` — everything one virtual machine reports.
    struct Info: VerbCommand {
        /// What `kernova info --help` says.
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Describe one virtual machine.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .info(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Reads the VM and writes it.
        func run() throws {
            let result = try answer()
            guard case .info(let info) = result else { throw result.unexpectedAnswer }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(info)
                    : TableRenderer.render(info, quiet: options.quiet))
        }
    }

    /// `kernova ip <vm>` — the guest's address, or why there isn't one.
    struct IP: VerbCommand {
        /// What `kernova ip --help` says.
        static let configuration = CommandConfiguration(
            commandName: "ip",
            abstract: "Print a guest's IP address.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// Keep asking until the guest has an address.
        @Flag(name: .long, help: "Keep asking until the guest has an address.")
        var wait = false

        /// How long `--wait` waits before giving up.
        @Option(name: .long, help: "Seconds to wait before giving up, with --wait.")
        var timeout: Double = 300

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Refuses a deadline that names no wait.
        func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .ipAddress(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Reads the address and writes it, or refuses with what stands in its
        /// way.
        func run() throws {
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
        /// `--wait` polls: the app reads the address off the host's table on a
        /// timer and emits no library event for it, so there is no signal to
        /// await. Only `notObserved` is worth waiting on — `unavailable` and
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
                guard wait, case .notObserved = address else { return address }
                guard Date() < deadline else {
                    throw CLIFailure(
                        .timedOut,
                        "\u{201C}\(vm)\u{201D} had no address within \(Int(timeout)) seconds.")
                }
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
        }

        /// How often `--wait` asks again.
        private static let pollInterval: TimeInterval = 1

        /// The one line an address prints, or the refusal it stands for.
        ///
        /// Only `.observed` is an address. The other three are answers to a
        /// different question — Kernova can see none, somebody else assigns
        /// it, not seen yet — so each refuses rather than printing prose a
        /// script would parse as an address.
        static func line(for address: GuestIPAddress, vm: String) throws -> String {
            switch address {
            case .observed(let value):
                return value
            case .notObserved:
                throw CLIFailure(
                    .refusedByState,
                    "Kernova has not seen \u{201C}\(vm)\u{201D} on its network.")
            case .externallyAssigned:
                throw CLIFailure(
                    .refusedByState,
                    "\u{201C}\(vm)\u{201D} is bridged, so your network assigns its address and "
                        + "Kernova cannot state it.")
            case .unavailable:
                throw CLIFailure(
                    .refusedByState,
                    "Kernova has no address for \u{201C}\(vm)\u{201D}.")
            }
        }
    }

    /// `kernova version` — which tool this is.
    struct Version: ParsableCommand {
        /// What `kernova version --help` says.
        ///
        /// It contacts nothing: the tool and the app it was installed from ship
        /// together, so this answers whether the tool works at all, without
        /// launching anything.
        static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Print this tool's version.")

        /// Writes the version.
        func run() throws {
            Console.out(KernovaCommand.toolVersion)
        }
    }
}
