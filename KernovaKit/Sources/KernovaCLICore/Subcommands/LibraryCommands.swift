import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// What `kernova clone` does with the source's machine identity.
    ///
    /// Neither flag follows Kernova's own clone preference, which is why this
    /// carries no third case: "whatever the app is set to" is the absence of a
    /// flag, not a flag of its own.
    public enum CloneIdentity: String, EnumerableFlag {
        /// Mint a fresh identity, so both virtual machines can run at once.
        case newIdentity
        /// Keep the source's identity, so the clone is the same machine to its
        /// guest.
        case keepIdentity

        /// The wire choice this flag names.
        var machineIdentity: CloneMachineIdentity {
            switch self {
            case .newIdentity: .new
            case .keepIdentity: .keep
            }
        }

        /// What each flag's help says.
        public static func help(for value: CloneIdentity) -> ArgumentHelp? {
            switch value {
            case .newIdentity: "Give the clone a fresh machine identity, so both can run at once."
            case .keepIdentity: "Keep the source's machine identity, which the two cannot share."
            }
        }
    }

    /// `kernova clone <vm>` — copy a virtual machine into a second one.
    public struct Clone: ParsableCommand {
        /// What `kernova clone --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "clone",
            abstract: "Copy a virtual machine into a new one.",
            discussion: "Returns once the copy has finished, printing the new virtual machine the "
                + "way `list` prints one row; --no-wait returns as soon as the copy has started, "
                + "printing the row while it is still being written. Without either identity flag "
                + "the clone follows Kernova's own clone preference.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// What the clone does with the source's machine identity; absent
        /// follows the app's preference.
        @Flag(exclusivity: .exclusive)
        public var identity: CloneIdentity?

        /// Return as soon as the copy has started.
        @Flag(name: .long, help: "Return without waiting for the copy to finish.")
        public var noWait = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Clones the VM and writes the row the copy produced.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            let answer = try client.send(
                .clone(selector, machineIdentity: identity?.machineIdentity ?? .followPreference)
            ).payload()
            guard case .summary(let created) = answer else { throw answer.unexpectedAnswer }
            let row = noWait ? created : try PreparingCopy.settle(created, on: client)
            try PreparingCopy.write(row, options: options)
        }
    }

    /// `kernova import <path>` — copy a bundle on this Mac into the library.
    public struct Import: ParsableCommand {
        /// What `kernova import --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Copy a virtual machine bundle into the library.",
            discussion: "The bundle at <path> is copied and the original left where it is. When "
                + "the path is not one Kernova may already read, it asks for permission on this "
                + "Mac's screen and this command waits for the answer. Returns once the copy has "
                + "finished, printing the imported virtual machine the way `list` prints one row; "
                + "--no-wait returns as soon as the copy has started. --timeout bounds the whole "
                + "wait, the permission answer included, and exits 7 when it runs out — a copy "
                + "already under way finishes in Kernova, the way --no-wait leaves it.")

        /// The bundle to copy, as this Mac names it.
        @Argument(help: "The path of the virtual machine bundle to import.")
        public var path: String

        /// Return as soon as the copy has started.
        @Flag(name: .long, help: "Return without waiting for the copy to finish.")
        public var noWait = false

        /// How long to wait before giving up; absent waits as long as it takes,
        /// which is what a person answering the permission panel needs.
        @Option(name: .long, help: "Seconds to wait before giving up.")
        public var timeout: Double?

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Refuses a deadline that names no wait.
        public func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// Imports the bundle and writes the row the copy produced.
        public func run() throws {
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            let row = try PreparingCopy.importing(
                Self.wirePath(for: path), waitingForTheCopy: !noWait, within: timeout,
                on: client)
            try PreparingCopy.write(row, options: options)
        }

        /// `path` as an absolute path, which is the only form the app can act
        /// on.
        ///
        /// Resolved against the shell's directory, which is `PWD` in the
        /// environment rather than the process's own: the tool is sandboxed,
        /// and a sandboxed process reads its working directory as its
        /// container (observed 2026-09-06, macOS 27 — a relative path crossed
        /// the wire under `~/Library/Containers/app.kernova.cli/Data`). Nothing
        /// on disk is consulted: the tool cannot read the file, so whether the
        /// path names a bundle is the app's question to answer.
        static func wirePath(
            for path: String,
            workingDirectory: String? = ProcessInfo.processInfo.environment["PWD"]
        ) -> String {
            let base = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
        }
    }

    /// `kernova rename <vm> <new-name>` — change a virtual machine's label.
    public struct Rename: ParsableCommand {
        /// What `kernova rename --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename a virtual machine.",
            discussion: "A display name is a label rather than an identifier, so one another "
                + "virtual machine already carries is accepted — and a later command naming it "
                + "exits 4 rather than choosing between them.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// What to call it instead.
        @Argument(help: "The new display name.")
        public var newName: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Renames the VM.
        public func run() throws {
            try CommandConnection.perform(
                .rename(
                    try SelectorParsing.selector(from: vm, forcingID: options.id),
                    newName: newName),
                launchIfNeeded: !options.noLaunch)
        }
    }

    /// `kernova delete <vm>` — take a virtual machine out of the library.
    public struct Delete: ParsableCommand {
        /// What `kernova delete --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a virtual machine.",
            discussion: "Moves the virtual machine's bundle to the Trash, leaving external files "
                + "it points at where they are; --permanent deletes the bundle outright instead. "
                + "Refuses without --yes, because the bundle is everything the virtual machine "
                + "is.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// Delete the bundle outright rather than moving it to the Trash.
        @Flag(name: .long, help: "Delete the bundle immediately, bypassing the Trash.")
        public var permanent = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Deletes the VM.
        public func run() throws {
            // External attachments are left alone: naming which files to take
            // with it is a choice the app's own sheet gathers, and a terminal
            // that cannot show what would go should not decide it silently.
            try CommandConnection.perform(
                .delete(
                    try SelectorParsing.selector(from: vm, forcingID: options.id),
                    permanently: permanent, alsoRemoving: [], confirmed: options.yes),
                launchIfNeeded: !options.noLaunch)
        }
    }

    /// `kernova reveal <vm>` — select the bundle in the Finder.
    public struct Reveal: ParsableCommand {
        /// What `kernova reveal --help` says.
        ///
        /// The Finder is what comes forward, not Kernova: this answers where
        /// the virtual machine lives, which is a question about a file.
        public static let configuration = CommandConfiguration(
            commandName: "reveal",
            abstract: "Select a virtual machine's bundle in the Finder.",
            discussion: "A virtual machine still being copied has no bundle to select — its "
                + "files are written under a staging path and published when the copy finishes — "
                + "so it refuses until then.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Reveals the VM's bundle.
        public func run() throws {
            try CommandConnection.perform(
                .showInFinder(try SelectorParsing.selector(from: vm, forcingID: options.id)),
                launchIfNeeded: !options.noLaunch)
        }
    }
}

/// The half a clone and an import share: a row answered while the copy behind
/// it is still being written, and the wait that turns it into the settled one.
enum PreparingCopy {
    /// Writes `row` the way `list` writes one row.
    static func write(_ row: VMSummary, options: GlobalOptions) throws {
        Console.out(
            options.format == .json
                ? try JSONRenderer.render(row)
                : TableRenderer.render([row], quiet: options.quiet))
    }

    /// The row an import settles into, bounded end to end by `timeout`.
    ///
    /// One deadline covers both round trips, because the first is where the
    /// wait can be unbounded: a path the sandbox does not admit puts a
    /// permission panel on the Mac's screen, and a script has nobody there to
    /// answer it.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/timedOut`` when `timeout`
    ///   runs out first. A copy the app has already started finishes there —
    ///   the deadline bounds this tool's wait, not Kernova's work.
    static func importing(
        _ wirePath: String, waitingForTheCopy waiting: Bool, within timeout: Double?,
        on client: VMCommandClient
    ) throws -> VMSummary {
        let deadline = timeout.map { ImportDeadline(seconds: $0, path: wirePath) }
        let answer = try bounded(by: deadline, on: client) {
            try client.send(.importVM(path: wirePath)).payload()
        }
        guard case .summary(let created) = answer else { throw answer.unexpectedAnswer }
        guard waiting else { return created }
        return try bounded(by: deadline, on: client) { try settle(created, on: client) }
    }

    /// When an import's `--timeout` runs out, and what it says when it does.
    private struct ImportDeadline {
        let expiresAt: Date
        let expiry: CLIFailure

        init(seconds: Double, path: String) {
            expiresAt = Date(timeIntervalSinceNow: seconds)
            expiry = CLIFailure(
                .timedOut,
                "\u{201C}\(path)\u{201D} was not imported within \(Int(seconds)) seconds.")
        }
    }

    /// Runs `body` with `client`'s read deadline armed to whatever is left of
    /// `deadline`, and the socket's own expiry reworded as what was waited for.
    ///
    /// A deadline already spent never reaches the socket: `SO_RCVTIMEO` reads a
    /// zero interval as no deadline at all.
    private static func bounded<T>(
        by deadline: ImportDeadline?, on client: VMCommandClient, _ body: () throws -> T
    ) throws -> T {
        guard let deadline else { return try body() }
        let remaining = deadline.expiresAt.timeIntervalSinceNow
        guard remaining > 0 else { throw deadline.expiry }
        client.waitForFrames(upTo: remaining)
        do {
            return try body()
        } catch let failure as CLIFailure where failure.code == .timedOut {
            throw deadline.expiry
        }
    }

    /// The row `created`'s copy settled into.
    ///
    /// Keyed on the identifier the app just answered with rather than on
    /// whatever the user typed: the source of a clone answers to that text too,
    /// and it is not the row being waited for.
    ///
    /// - Throws: ``CLIFailure`` carrying the copy's own failure — the wait
    ///   raises what the copy would have reported to the app, so a script sees
    ///   the same refusal a person would.
    static func settle(_ created: VMSummary, on client: VMCommandClient) throws -> VMSummary {
        let answer = try client.send(.awaitPreparing(.id(created.id))).payload()
        guard case .summary(let settled) = answer else { throw answer.unexpectedAnswer }
        return settled
    }
}
