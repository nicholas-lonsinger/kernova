import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova snapshot` — the verbs that address a virtual machine's restore
    /// points.
    public struct Snapshot: ParsableCommand {
        /// What `kernova snapshot --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "snapshot",
            abstract: "Work with a virtual machine's snapshots.",
            discussion: "Every verb here names its snapshot by name or identifier, matched "
                + "against the virtual machine's own list — a name several snapshots carry "
                + "exits 4 listing their identifiers.",
            subcommands: [List.self, Take.self, Revert.self, Delete.self, Rename.self])

        /// Creates the parent command; a bare `kernova snapshot` prints this
        /// help.
        public init() {}
    }
}

extension KernovaCommand.Snapshot {
    /// `kernova snapshot list <vm>` — every restore point the bundle holds.
    public struct List: GlobalOptionsCommand {
        /// What `kernova snapshot list --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List a virtual machine's snapshots.",
            discussion: "Sizes count blocks a snapshot shares with the virtual machine's own "
                + "disks in full, so they state what the files occupy rather than what deleting "
                + "the snapshot would free.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Reads the restore points and writes them.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            let rows = try KernovaCommand.Snapshot.rows(of: selector, from: client)
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(rows)
                    : TableRenderer.render(rows, quiet: options.quiet))
        }
    }

    /// `kernova snapshot take <vm>` — capture the state to come back to.
    public struct Take: GlobalOptionsCommand {
        /// What `kernova snapshot take --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "take",
            abstract: "Take a snapshot of a virtual machine.",
            discussion: "A running guest is captured with its memory and pauses briefly while "
                + "the state is written; a stopped one is captured as disks alone. Without "
                + "--name Kernova names the snapshot the way its own sheet proposes: "
                + "\u{201C}Snapshot\u{201D}, then \u{201C}Snapshot 2\u{201D}, and so on. Prints "
                + "the new snapshot as one row of `snapshot list`.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// What to call the capture; empty leaves the naming to Kernova.
        @Option(name: .long, help: "What to call the snapshot.")
        public var name: String = ""

        /// The free-form note to file with it.
        @Option(name: .long, help: "A note to keep with the snapshot.")
        public var notes: String = ""

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Takes the snapshot and writes the row it produced.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            let answer = try client.send(
                .takeSnapshot(selector, name: name, notes: notes)
            ).payload()
            guard case .snapshot(let taken) = answer else { throw answer.unexpectedAnswer }
            // The same size read `snapshot list` performs, so a script parsing
            // either verb's answer finds one shape.
            let sizes = try KernovaCommand.Snapshot.sizes(of: selector, from: client)
            let row = SnapshotRow(taken, onDiskBytes: sizes[taken.id])
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(row)
                    : TableRenderer.render([row], quiet: options.quiet))
        }
    }

    /// `kernova snapshot revert <vm> <snapshot>` — put the VM back.
    public struct Revert: VMScopedCommandLine {
        /// What `kernova snapshot revert --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "revert",
            abstract: "Return a virtual machine to one of its snapshots.",
            discussion: "The state the virtual machine is in now is captured as a check-point "
                + "first, so the revert is undoable; --no-checkpoint discards it instead. "
                + "Refuses without --yes, because everything since the snapshot goes.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// Which snapshot, by name or identifier.
        @Argument(help: "The snapshot's name or identifier.", completion: CompletionSource.snapshot)
        public var snapshot: String

        /// Whether to capture the current state before rolling back.
        ///
        /// Exclusive rather than last-wins, for the reason `stop`'s methods
        /// are: a line asking for both has not said which one it meant.
        @Flag(
            inversion: .prefixedNo, exclusivity: .exclusive,
            help: "Capture the current state as a snapshot before reverting.")
        public var checkpoint = true

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Reverts the VM.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            let target = try KernovaCommand.Snapshot.resolve(
                snapshot, of: vm, selector: selector, forcingID: options.id, from: client)
            _ = try client.send(
                .revertToSnapshot(
                    selector, snapshot: target.id, takingCheckpoint: checkpoint,
                    confirmed: options.yes)
            ).payload()
        }
    }

    /// `kernova snapshot delete <vm> <snapshot>` — drop one restore point.
    public struct Delete: VMScopedCommandLine {
        /// What `kernova snapshot delete --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one of a virtual machine's snapshots.",
            discussion: "The snapshot's captured files are moved to the Trash and the virtual "
                + "machine is left as it is. Refuses without --yes, because nothing else can "
                + "return the virtual machine to that state afterwards.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// Which snapshot, by name or identifier.
        @Argument(help: "The snapshot's name or identifier.", completion: CompletionSource.snapshot)
        public var snapshot: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Deletes the snapshot.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            let target = try KernovaCommand.Snapshot.resolve(
                snapshot, of: vm, selector: selector, forcingID: options.id, from: client)
            _ = try client.send(
                .deleteSnapshot(selector, snapshot: target.id, confirmed: options.yes)
            ).payload()
        }
    }

    /// `kernova snapshot rename <vm> <snapshot> <new-name>` — relabel one.
    public struct Rename: VMScopedCommandLine {
        /// What `kernova snapshot rename --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename one of a virtual machine's snapshots.",
            discussion: "A snapshot's name is a label rather than an identifier, so one another "
                + "snapshot of the same virtual machine already carries is accepted — and a "
                + "later command naming it exits 4 rather than choosing between them.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// Which snapshot, by name or identifier.
        @Argument(help: "The snapshot's name or identifier.", completion: CompletionSource.snapshot)
        public var snapshot: String

        /// What to call it instead.
        @Argument(help: "The new snapshot name.")
        public var newName: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Renames the snapshot.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            let target = try KernovaCommand.Snapshot.resolve(
                snapshot, of: vm, selector: selector, forcingID: options.id, from: client)
            _ = try client.send(
                .renameSnapshot(selector, snapshot: target.id, newName: newName)
            ).payload()
        }
    }
}

extension KernovaCommand.Snapshot {
    /// The VM's restore points, each paired with what its files occupy.
    static func rows(
        of selector: VMSelector, from client: VMCommandClient
    ) throws -> [SnapshotRow] {
        let listed = try summaries(of: selector, from: client)
        // Skipped for a VM with nothing captured: the walk would answer an
        // empty map, and asking for it is a round trip that tells nobody
        // anything.
        guard !listed.isEmpty else { return [] }
        let sizes = try sizes(of: selector, from: client)
        return listed.map { SnapshotRow($0, onDiskBytes: sizes[$0.id]) }
    }

    /// The VM's restore points, as the app lists them.
    static func summaries(
        of selector: VMSelector, from client: VMCommandClient
    ) throws -> [SnapshotSummary] {
        let answer = try client.send(.snapshots(selector)).payload()
        guard case .snapshots(let listed) = answer else { throw answer.unexpectedAnswer }
        return listed
    }

    /// Bytes each of the VM's restore points occupies, by identifier.
    static func sizes(
        of selector: VMSelector, from client: VMCommandClient
    ) throws -> [UUID: UInt64] {
        let answer = try client.send(.snapshotOnDiskBytes(selector)).payload()
        guard case .snapshotSizes(let sizes) = answer else { throw answer.unexpectedAnswer }
        return sizes
    }

    /// The snapshot `text` names, matched against the VM's own listing.
    ///
    /// The wire addresses a snapshot by identifier alone, so a typed name is
    /// resolved here — against the listing rather than by asking the app to
    /// search, which keeps one set of matching rules for both arguments.
    static func resolve(
        _ text: String, of vm: String, selector: VMSelector, forcingID: Bool,
        from client: VMCommandClient
    ) throws -> SnapshotSummary {
        try SnapshotResolution.snapshot(
            named: text, of: vm, in: try summaries(of: selector, from: client),
            forcingID: forcingID)
    }
}
