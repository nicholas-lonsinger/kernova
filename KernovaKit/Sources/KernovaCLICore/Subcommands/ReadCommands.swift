import ArgumentParser
import Foundation
import KernovaCommandModel
import KernovaConsole

extension KernovaCommand {
    /// `kernova list` — the virtual machines a filter admits, in library order
    /// unless `--sort` says otherwise.
    struct List: VerbCommand {
        /// What `kernova list --help` says.
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List virtual machines.",
            discussion: "With no filter, lists every virtual machine. Repeating a filter flag "
                + "widens it: a virtual machine passes when it matches any value given. A virtual "
                + "machine is listed only when it passes every flag given and is in the smart "
                + "group or folder named, as the sidebar lists it. Under the manual sort, a folder's "
                + "virtual machines are listed in the folder's own order.")

        @OptionGroup var filter: ListFilterOptions

        @OptionGroup var groups: GroupTargetOptions

        @Option(name: .long, help: "The order to list them in.")
        var sort: VMLibrarySort = .manual

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .list(
                VMListQuery(
                    filter: filter.filter, networks: filter.networks, tags: filter.tags, groups: groups.groups,
                    sort: sort))
        }

        /// Reads the library and writes it.
        func run() throws {
            try answer { result in
                guard case .summaries(let rows) = result else { throw result.unexpectedAnswer }
                Console.out(
                    options.format == .json
                        ? try JSONRenderer.render(rows)
                        : TableRenderer.render(rows, quiet: options.quiet))
            }
        }
    }

    /// `kernova groups` — the library's groups and the VMs in each.
    struct Groups: VerbCommand {
        /// What `kernova groups --help` says.
        static let configuration = CommandConfiguration(
            commandName: "groups",
            abstract: "List the library's smart groups and folders.",
            discussion: "Each row names the virtual machines in the group, which `kernova list "
                + "--smart-group` or `--folder` lists: the smart groups, then the folders, in the "
                + "order the sidebar shows them.")

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb { .groups }

        /// Reads the groups and writes them.
        func run() throws {
            try answer { answered in
                guard case .groups(let groups) = answered else { throw answered.unexpectedAnswer }
                Console.out(
                    options.format == .json
                        ? try JSONRenderer.render(groups)
                        : TableRenderer.render(groups, quiet: options.quiet))
            }
        }
    }

    /// `kernova info <vm>` — everything one virtual machine reports.
    struct Info: GlobalOptionsCommand {
        /// What `kernova info --help` says.
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Describe one virtual machine.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Reads the VM and writes it.
        func run() throws {
            let selector = try selector()
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            Console.out(try output(for: selector, from: client))
        }

        /// The VM this command line names, decided before Kernova is started
        /// to hear it.
        ///
        /// - Throws: ``CLIFailure`` with ``CLIExitCode/usage`` for `--id` on
        ///   something that is not an identifier.
        func selector() throws -> VMSelector {
            try SelectorParsing.selector(from: vm, forcingID: options.id)
        }

        /// What this command line prints for the VM `selector` names, read
        /// through `client`.
        ///
        /// The disks are asked for by the identifier the first answer carries,
        /// so both reads describe one VM whatever is renamed between them.
        /// `--quiet` text is the name alone, which needs no disk read.
        func output(for selector: VMSelector, from client: VMCommandClient) throws -> String {
            let described = try client.send(.info(selector)).payload()
            guard case .info(let info) = described else { throw described.unexpectedAnswer }
            guard options.format == .json || !options.quiet else { return info.name }
            let listed = try client.send(.storageDisks(.id(info.id))).payload()
            guard case .storageDisks(let disks) = listed else { throw listed.unexpectedAnswer }
            let report = VMInfoReport(info, storageDisks: disks)
            return options.format == .json ? try JSONRenderer.render(report) : TableRenderer.render(report)
        }
    }

    /// `kernova ip <vm>` — the guest's address, or why there isn't one.
    struct IP: VerbCommand {
        /// What `kernova ip --help` says.
        static let configuration = CommandConfiguration(
            commandName: "ip",
            abstract: "Print a guest's IP address.",
            discussion: "--wait waits as `kernova wait --until address` does, then prints the address.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// Wait until Kernova has seen the guest use an address.
        @Flag(name: .long, help: "Wait until Kernova has seen the guest use an address.")
        var wait = false

        /// How long `--wait` waits before giving up.
        @Option(name: .long, help: "Seconds to wait before giving up, with --wait.")
        var timeout: Double = TimeoutOption.waitDefault

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Refuses a deadline that names no wait.
        func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// The request this command line stands for: the address as it stands,
        /// or the wait for one.
        func verb() throws -> VMCommandRequest.Verb {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            return wait ? .wait(selector, until: .address, timeout: timeout) : .ipAddress(selector)
        }

        /// Reads the address and writes it, or refuses with what stands in its
        /// way.
        func run() throws {
            try answer { answered in
                let address: GuestIPAddress
                switch answered {
                case .ipAddress(let read) where !wait: address = read
                case .info(let info) where wait: address = info.ipAddress
                default: throw answered.unexpectedAnswer
                }
                // Classified before either renderer runs, so both formats exit
                // the same way: an answer that is not an address refuses
                // whether or not JSON could have described it.
                let line = try Self.line(for: address, vm: vm)
                Console.out(options.format == .json ? try JSONRenderer.render(address) : line)
            }
        }

        /// The one line an address prints, or the refusal it stands for.
        ///
        /// Only `.observed` is an address. The other three are answers to a
        /// different question — Kernova can see none, somebody else assigns
        /// it, not seen yet — so each refuses rather than printing prose a
        /// script would parse as an address.
        static func line(for address: GuestIPAddress, vm: String) throws -> String {
            if let absence = address.absence { throw CLIFailure(.refusedByState, absence.sentence(vm: vm)) }
            return address.address ?? ""
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
