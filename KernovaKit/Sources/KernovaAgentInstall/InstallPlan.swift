/// Everything an agent's `install` or `uninstall` does in one scope, as data: what it writes and removes, and
/// the commands it runs. ``steps`` puts it in the order ``Installer`` carries it out, and is both what a dry run
/// prints and what the installer performs and reports, one step at a time.
///
/// The tree under ``root`` is the one the system scope's account owns. The installer reaches it only through
/// descriptors and hands what it makes there to the account (``Installer``); an uninstall empties it the same
/// way, then removes it. Everything else is written by, and belongs to, whoever runs the installer.
public struct InstallPlan: Equatable, Sendable {
    /// One thing written.
    public enum Write: Equatable, Sendable {
        /// A directory, made with `mode` when missing; one already there keeps its own.
        case directory(path: String, mode: UInt16)
        /// A file holding `text` with `mode`, replaced whole unless it already is exactly that.
        case file(path: String, mode: UInt16, text: String)
        /// The payload the installer carries, landed as `payloadName` by its format's ``PayloadLander`` in the
        /// slot of `root` that `current` does not name — ``InstallRoot/firstSlotName`` when it names none — then
        /// recorded alone in the slot metadata, `rollback` pointed at it, and `current` switched to it, last, as
        /// an update's switch moves it: no slot a running peer runs from is written, every peer running from the
        /// root follows the switch, and `rollback` names no slot the install did not just land.
        case freshSlot(root: InstallRoot, payloadName: String)
    }

    /// One command run, from `PATH`, unless the installer was asked to run none.
    public struct Command: Equatable, Sendable {
        /// The command and its arguments.
        public var arguments: [String]
        /// The command runs only when this path exists.
        public var onlyIfPresent: String?

        /// Runs `arguments`, only when `onlyIfPresent` exists if it is set.
        public init(_ arguments: [String], onlyIfPresent: String? = nil) {
            self.arguments = arguments
            self.onlyIfPresent = onlyIfPresent
        }
    }

    /// The agent's own root, which ``treeRemovals`` and ``treeWrites`` stay inside.
    public var root: String
    /// Commands run before anything is written or removed.
    public var before: [Command] = []
    /// What is removed under ``root`` before anything is written.
    public var treeRemovals: [String] = []
    /// What is written under ``root``, in order.
    public var treeWrites: [Write] = []
    /// What is written outside ``root``, in order.
    public var writes: [Write] = []
    /// What is removed outside ``root``, files and links singly; a missing one is skipped.
    public var removals: [String] = []
    /// Whether ``root`` is emptied and removed.
    public var removesRoot = false
    /// Commands run after.
    public var after: [Command] = []

    /// One thing the installer does.
    public enum Step: Equatable, Sendable {
        /// Runs a command; skipped when its ``Command/onlyIfPresent`` path is absent.
        case run(Command)
        /// Removes a path under ``root``, a directory with everything in it.
        case removeBelowRoot(String)
        /// Makes ``root`` when it is missing.
        case makeRoot(String)
        /// Writes under ``root``.
        case writeBelowRoot(Write)
        /// Writes outside ``root``.
        case write(Write)
        /// Removes a file or link outside ``root``.
        case remove(String)
        /// Empties ``root`` and removes it.
        case removeRoot(String)
    }

    /// The plan in the order it is carried out: ``before``, ``treeRemovals``, the agent's own ``root`` made,
    /// ``treeWrites``, ``writes``, ``removals``, the root emptied and removed when ``removesRoot``, then
    /// ``after``.
    public var steps: [Step] {
        var steps = before.map(Step.run) + treeRemovals.map(Step.removeBelowRoot)
        if !treeWrites.isEmpty { steps += [.makeRoot(root)] + treeWrites.map(Step.writeBelowRoot) }
        steps += writes.map(Step.write) + removals.map(Step.remove)
        if removesRoot { steps.append(.removeRoot(root)) }
        return steps + after.map(Step.run)
    }

    /// The install of one scope: the agent's root laid out at `root`, its payload landed as `payloadName` in a
    /// fresh slot (``Write/freshSlot(root:payloadName:)``), and `definitions` around it.
    ///
    /// Before it writes anything it clears any switch an update left pending, or reverted, so no rollback check
    /// judges the fresh install (``ServiceDefinitions/beforeInstall`` has stopped the check by then).
    public static func install(
        root: InstallRoot, payloadName: String, definitions: some ServiceDefinitions
    ) -> InstallPlan {
        var plan = InstallPlan(root: root.path)
        plan.before = definitions.beforeInstall
        plan.treeRemovals = [root.switchPending, root.switchRejected]
        plan.treeWrites = [
            .directory(path: root.slots, mode: 0o755),
            .freshSlot(root: root, payloadName: payloadName),
        ]
        plan.writes = definitions.writes
        plan.after = definitions.afterInstall
        return plan
    }

    /// The uninstall of one scope: stops what runs, then removes every file `definitions` writes and the agent's
    /// root with everything in it.
    public static func uninstall(root: InstallRoot, definitions: some ServiceDefinitions) -> InstallPlan {
        var plan = InstallPlan(root: root.path)
        plan.before = definitions.beforeUninstall
        plan.removals = definitions.files
        plan.removesRoot = true
        plan.after = definitions.afterUninstall
        return plan
    }

    /// What an agent rewrites so the files its service manager runs it from are the ones its own binary writes:
    /// everything `definitions` writes, then the manager told to read them again.
    public static func refresh(root: InstallRoot, definitions: some ServiceDefinitions) -> InstallPlan {
        var plan = InstallPlan(root: root.path)
        plan.writes = definitions.writes
        plan.after = definitions.afterRefresh
        return plan
    }

    /// What a dry run of `plan` prints, `heading` first: one line per step.
    public static func dryRun(_ plan: InstallPlan, heading: String) -> [String] {
        [heading] + plan.steps.map { "  " + $0.description }
    }
}

extension InstallPlan.Step: CustomStringConvertible {
    /// The step as one line: what a dry run lists, and what the installer prints as it takes it.
    public var description: String {
        switch self {
        case .run(let command):
            let line = "run " + command.arguments.map(Self.quoted).joined(separator: " ")
            return command.onlyIfPresent.map { line + ", if \($0) exists" } ?? line
        case .removeBelowRoot(let path): return "remove \(path), if present"
        case .makeRoot(let path): return "make directory \(path), if missing"
        case .writeBelowRoot(let write), .write(let write):
            switch write {
            case .directory(let path, _): return "make directory \(path), if missing"
            case .file(let path, _, _): return "write \(path)"
            case .freshSlot(let root, let payloadName):
                return
                    "write the agent as \(payloadName) in the slot under \(root.slots) that \(root.current) does not "
                    + "name, record it in \(root.state), point \(root.rollback) at it, and switch \(root.current) "
                    + "to it"
            }
        case .remove(let path): return "remove \(path), if present"
        case .removeRoot(let path): return "remove \(path) and everything in it, if present"
        }
    }

    /// `argument` as a shell would need it typed: single-quoted when it holds anything but plain ASCII.
    private static func quoted(_ argument: String) -> String {
        let plain = !argument.isEmpty && argument.utf8.allSatisfy { Self.plainBytes.contains($0) }
        return plain
            ? argument
            : "'"
                + argument.split(separator: "'", omittingEmptySubsequences: false)
                .joined(separator: #"'\''"#) + "'"
    }

    private static let plainBytes = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@+,".utf8)
}
