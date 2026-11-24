import ArgumentParser
import Foundation
import KernovaCommandModel
import KernovaConsole

extension KernovaCommand {
    /// `kernova snapshot` — the verbs that address a virtual machine's restore
    /// points.
    struct Snapshot: ParsableCommand {
        /// What `kernova snapshot --help` says.
        static let configuration = CommandConfiguration(
            commandName: "snapshot",
            abstract: "Work with a virtual machine's snapshots.",
            discussion: "Every verb here names its snapshot by name or identifier, matched "
                + "against the virtual machine's own list — a name several snapshots carry "
                + "exits 4 listing their identifiers.",
            subcommands: [List.self, Take.self, Revert.self, Delete.self, Rename.self, Notes.self])
    }
}

extension KernovaCommand.Snapshot {
    /// `kernova snapshot list <vm>` — every restore point the bundle holds.
    struct List: GlobalOptionsCommand {
        /// What `kernova snapshot list --help` says.
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List a virtual machine's snapshots.",
            discussion: "SIZE counts everything a snapshot holds. On a volume that can clone "
                + "files, such as APFS, PRIVATE is the part no other file shares: the space freed "
                + "once the snapshot is deleted and the Trash is emptied. Space shared with the "
                + "virtual machine's disks or with another snapshot isn't private, so deleting one "
                + "can raise another's PRIVATE. On a volume that can't clone files, each snapshot "
                + "is a full copy, SIZE is the space freed, and PRIVATE reads \u{2013}.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Reads the restore points and writes them.
        func run() throws {
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
    struct Take: GlobalOptionsCommand {
        /// What `kernova snapshot take --help` says.
        static let configuration = CommandConfiguration(
            commandName: "take",
            abstract: "Take a snapshot of a virtual machine.",
            discussion: "A snapshot captures the VM's disks and settings. A running guest's "
                + "memory is captured with them, and it pauses briefly while the state is "
                + "written; a stopped one is captured with no memory. A VM whose guest can "
                + "write to an external disk is snapshotted only while stopped. Without "
                + "--name Kernova names the snapshot the way its own sheet proposes: "
                + "\u{201C}Snapshot\u{201D}, then \u{201C}Snapshot 2\u{201D}, and so on. Prints "
                + "the new snapshot as one row of `snapshot list`.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// What to call the capture; empty leaves the naming to Kernova.
        @Option(name: .long, help: "What to call the snapshot.")
        var name: String = ""

        /// The free-form note to file with it.
        @Option(name: .long, help: "A note to keep with the snapshot.")
        var notes: String = ""

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Takes the snapshot and writes the row it produced.
        func run() throws {
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
            let row = SnapshotRow(taken, size: sizes[taken.id])
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(row)
                    : TableRenderer.render([row], quiet: options.quiet))
        }
    }

    /// `kernova snapshot revert <vm> <snapshot>` — put the VM back.
    struct Revert: VMScopedCommandLine {
        /// What `kernova snapshot revert --help` says.
        static let configuration = CommandConfiguration(
            commandName: "revert",
            abstract: "Return a virtual machine to one of its snapshots.",
            discussion: "Refuses without --yes, because everything since the snapshot goes; "
                + "`kernova snapshot take` first keeps the state the virtual machine is in now.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// Which snapshot, by name or identifier.
        @Argument(help: "The snapshot's name or identifier.", completion: CompletionSource.snapshot)
        var snapshot: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Reverts the VM.
        func run() throws {
            try KernovaCommand.Snapshot.perform(on: snapshot, of: vm, options: options) {
                .revertToSnapshot($0, snapshot: $1, consent: options.consent)
            }
        }
    }

    /// `kernova snapshot delete <vm> <snapshot>` — drop one restore point.
    struct Delete: VMScopedCommandLine {
        /// What `kernova snapshot delete --help` says.
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete one of a virtual machine's snapshots.",
            discussion: "The snapshot's captured files are moved to the Trash and the virtual "
                + "machine is left as it is. Refuses without --yes, because nothing else can "
                + "return the virtual machine to that state afterwards.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// Which snapshot, by name or identifier.
        @Argument(help: "The snapshot's name or identifier.", completion: CompletionSource.snapshot)
        var snapshot: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Deletes the snapshot.
        func run() throws {
            try KernovaCommand.Snapshot.perform(on: snapshot, of: vm, options: options) {
                .deleteSnapshot($0, snapshot: $1, consent: options.consent)
            }
        }
    }

    /// `kernova snapshot rename <vm> <snapshot> <new-name>` — relabel one.
    struct Rename: VMScopedCommandLine {
        /// What `kernova snapshot rename --help` says.
        static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename one of a virtual machine's snapshots.",
            discussion: "A snapshot's name is a label rather than an identifier, so one another "
                + "snapshot of the same virtual machine already carries is accepted — and a "
                + "later command naming it exits 4 rather than choosing between them.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// Which snapshot, by name or identifier.
        @Argument(help: "The snapshot's name or identifier.", completion: CompletionSource.snapshot)
        var snapshot: String

        /// What to call it instead.
        @Argument(help: "The new snapshot name.")
        var newName: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Renames the snapshot.
        func run() throws {
            try KernovaCommand.Snapshot.perform(on: snapshot, of: vm, options: options) {
                .renameSnapshot($0, snapshot: $1, newName: newName)
            }
        }
    }

    /// `kernova snapshot notes <vm> <snapshot> <text>` — replace one's note.
    struct Notes: VMScopedCommandLine {
        /// What `kernova snapshot notes --help` says.
        static let configuration = CommandConfiguration(
            commandName: "notes",
            abstract: "Replace the note kept with one of a virtual machine's snapshots.",
            discussion: "Leading and trailing spaces and line breaks are trimmed, and an empty "
                + "<text> clears the note.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// Which snapshot, by name or identifier.
        @Argument(help: "The snapshot's name or identifier.", completion: CompletionSource.snapshot)
        var snapshot: String

        /// The note to keep instead.
        @Argument(help: "The new note; empty to clear it.")
        var text: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Replaces the snapshot's note.
        func run() throws {
            try KernovaCommand.Snapshot.perform(on: snapshot, of: vm, options: options) {
                .setSnapshotNotes($0, snapshot: $1, notes: text)
            }
        }
    }
}

extension KernovaCommand.Snapshot {
    /// The VM's restore points, each paired with its size.
    static func rows(
        of selector: VMSelector, from client: VMCommandClient
    ) throws -> [SnapshotRow] {
        let listed = try summaries(of: selector, from: client)
        // Skipped for a VM with nothing captured: the walk would answer an
        // empty map, and asking for it is a round trip that tells nobody
        // anything.
        guard !listed.isEmpty else { return [] }
        let sizes = try sizes(of: selector, from: client)
        return listed.map { SnapshotRow($0, size: sizes[$0.id]) }
    }

    /// The VM's restore points, as the app lists them.
    static func summaries(
        of selector: VMSelector, from client: VMCommandClient
    ) throws -> [SnapshotSummary] {
        let answer = try client.send(.snapshots(selector)).payload()
        guard case .snapshots(let listed) = answer else { throw answer.unexpectedAnswer }
        return listed
    }

    /// The size of each of the VM's restore points, by identifier.
    static func sizes(
        of selector: VMSelector, from client: VMCommandClient
    ) throws -> [UUID: SnapshotSize] {
        let answer = try client.send(.snapshotSizes(selector)).payload()
        guard case .snapshotSizes(let sizes) = answer else { throw answer.unexpectedAnswer }
        return sizes
    }

    /// Sends the request `verb` builds for the snapshot `text` names on the
    /// virtual machine `vm` names, handing it the VM's selector and the
    /// snapshot's identifier.
    ///
    /// The wire addresses a snapshot by identifier alone, so `text` is matched
    /// here against the VM's own listing (``SnapshotResolution``), and the
    /// identifier `verb` is handed is always one that listing carries. That is
    /// what refuses a snapshot the VM doesn't list: the app takes a rename or a
    /// note edit naming one as a no-op.
    static func perform(
        on text: String, of vm: String, options: GlobalOptions,
        _ verb: (VMSelector, UUID) -> VMCommandRequest.Verb
    ) throws {
        let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
        let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
        defer { client.close() }
        let target = try SnapshotResolution.snapshot(
            named: text, of: vm, in: try summaries(of: selector, from: client),
            forcingID: options.id)
        _ = try client.send(verb(selector, target.id)).payload()
    }
}
