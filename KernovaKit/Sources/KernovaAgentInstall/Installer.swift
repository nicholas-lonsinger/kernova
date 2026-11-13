#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaDigest
import KernovaFileTree

/// Carries out an ``InstallPlan``: writes each file whole (``StagedFile``), then runs its commands.
///
/// The agent's own root may belong to an account other than the installer's, which can change anything under
/// it: the system scope's account. So the installer never resolves a name under the root by path. It makes the
/// root itself when it is missing, opens it without following a link, and reaches everything below through
/// the root's ``InstallDirectory``, one name at a time relative to an open directory; each owner and mode is
/// set on the descriptor of what the installer just made, so no privileged call below the root changes an
/// entry by name. A link the account planted is refused or removed, never followed. Every directory and file
/// written belongs to the account, which updates its own slots there. A link stays the installer's: giving it
/// an owner could only be done by name, and its owner grants nothing, since the account replaces or removes it
/// as the owner of its directory. Above the root, and for the service manager's directories, any path that
/// `stat`s as a directory will do, as `mkdir -p` takes it.
public struct Installer {
    /// What failed, and where.
    public enum Failure: InstallFileFailure, CustomStringConvertible {
        /// A system call on `path` failed with `errno`.
        case system(operation: String, path: String, errno: Int32)
        /// The JSON encoder refused the slot metadata.
        case encoding(String)
        /// A directory could not be removed.
        case removal(path: String, detail: String)
        /// `arguments` could not be started, or exited `status`.
        case command(arguments: [String], status: Int32)
        /// The account the system scope's root belongs to does not exist.
        case noAccount(String)
        /// The directory at `path` could not be packed as the payload.
        case packing(path: String, detail: String)

        /// ``system(operation:path:errno:)``.
        public init(operation: String, path: String, errno: Int32) {
            self = .system(operation: operation, path: path, errno: errno)
        }

        /// The failure as the installer prints it.
        public var description: String {
            switch self {
            case .system(let operation, let path, let errno):
                "\(operation) \(path): \(String(cString: strerror(errno)))"
            case .encoding(let detail): "cannot encode state.json: \(detail)"
            case .removal(let path, let detail): "cannot remove \(path): \(detail)"
            case .command(let arguments, let status):
                status < 0
                    ? "cannot run \(arguments.joined(separator: " "))"
                    : "\(arguments.joined(separator: " ")) exited \(status)"
            case .noAccount(let name): "the \(name) account does not exist"
            case .packing(let path, let detail): "cannot pack \(path): \(detail)"
            }
        }
    }

    /// Prefixed to every path written, removed or checked; empty for the live system.
    let stagingRoot: String
    /// Whether commands run.
    let runsCommands: Bool
    /// The payload a `.payload` write lands; nil for an installer whose plans write none.
    let payloadSource: InstallPayloadSource?
    /// What lands it.
    let lander: any PayloadLander
    /// The display version the payload reports.
    let versionLabel: String
    /// The account the plan's root and everything in it belong to; nil for the invoker, as in the user scope
    /// and a staging root.
    let account: String?
    private let fileSystem = POSIXTreeFileSystem()

    /// An installer writing below `stagingRoot` — empty for the live system — and running commands when
    /// `runsCommands`, whose `.payload` write lands `payloadSource` through `lander`, recorded as `versionLabel`,
    /// and whose root belongs to `account`.
    public init(
        stagingRoot: String, runsCommands: Bool, payloadSource: InstallPayloadSource?, lander: any PayloadLander,
        versionLabel: String, account: String?
    ) {
        self.stagingRoot = stagingRoot
        self.runsCommands = runsCommands
        self.payloadSource = payloadSource
        self.lander = lander
        self.versionLabel = versionLabel
        self.account = account
    }

    /// The ids the plan's root belongs to.
    struct Owner: Sendable {
        var uid: uid_t
        var gid: gid_t
    }

    /// Runs `plan`'s ``InstallPlan/steps`` in order, handing `report` each one's description just before it
    /// takes it; a command not run, as with `runsCommands` false or its path absent, is not reported. Answers
    /// the paths of the files it wrote: a file outside the root that already held its text is not among them.
    @discardableResult
    public func run(_ plan: InstallPlan, report: (String) -> Void = { _ in }) throws(Failure) -> [String] {
        let source = try openPayload(plan)
        defer { if let source { close(source) } }
        // The root open for the steps below it: as found until the plan makes it, then as made and handed to
        // its owner, whose account the commands before it create.
        var root: InstallDirectory<Failure>?
        var written: [String] = []
        for step in plan.steps {
            if case .run(let command) = step, !willRun(command) { continue }
            report(step.description)
            switch step {
            case .run(let command):
                let status = Self.spawn(command.arguments)
                guard status == 0 else { throw .command(arguments: command.arguments, status: status) }
            case .removeBelowRoot(let path):
                if root == nil { root = try openRoot(plan.root) }
                switch root {
                case .some(let found): try removeBelow(found, plan.root, path)
                case .none: break
                }
            case .makeRoot:
                root = nil
                root = try makeRoot(plan.root, owner: try resolveOwner())
            case .writeBelowRoot(let write):
                switch root {
                case .some(let made): try performBelow(made, plan.root, write, source: source)
                case .none: preconditionFailure("\(step) before the root is made")
                }
                if case .file(let path, _, _) = write { written.append(path) }
            case .write(let write):
                if try perform(write, source: source), case .file(let path, _, _) = write { written.append(path) }
            case .remove(let path):
                try remove(path)
            case .removeRoot:
                root = nil
                try removeRoot(plan.root)
            }
        }
        return written
    }

    /// Removes the agent's root and everything in it, never following a link; a missing one is skipped.
    private func removeRoot(_ path: String) throws(Failure) {
        let parent: InstallDirectory<Failure>
        do { parent = try openParent(of: path) } catch .system(_, _, ENOENT) { return }
        _ = try parent.removeTree(Self.lastComponent(of: path))
    }

    /// Opens the payload `plan` writes, before any step, so a missing one changes nothing: the file, or the
    /// directory that is packed.
    private func openPayload(_ plan: InstallPlan) throws(Failure) -> Int32? {
        guard plan.treeWrites.contains(where: { if case .freshSlot = $0 { true } else { false } }) else { return nil }
        guard let payloadSource else { preconditionFailure("a plan writing a payload, given none") }
        let flags =
            switch payloadSource {
            case .file: O_RDONLY | O_CLOEXEC
            case .packedDirectory: O_RDONLY | O_DIRECTORY | O_CLOEXEC
            }
        let source = open(payloadSource.path, flags)
        guard source >= 0 else { throw .system(operation: "open", path: payloadSource.path, errno: errno) }
        return source
    }

    private func resolveOwner() throws(Failure) -> Owner? {
        guard let account else { return nil }
        guard let entry = getpwnam(account) else { throw .noAccount(account) }
        return Owner(uid: entry.pointee.pw_uid, gid: entry.pointee.pw_gid)
    }

    // MARK: Outside the root

    private func staged(_ path: String) -> String { stagingRoot + path }

    /// Carries out `write`: false when it found the file already holding its text, and wrote nothing.
    private func perform(_ write: InstallPlan.Write, source: Int32?) throws(Failure) -> Bool {
        switch write {
        case .directory(let path, let mode):
            try makeDirectory(path, mode: mode)
            return true
        case .file(let path, let mode, let text):
            let parent = try openParent(of: path)
            let name = Self.lastComponent(of: path)
            let bytes = Array(text.utf8)
            // A service manager may act on any write to its files: on macOS 27.2, writing a launchd property list
            // raised a "Background Activity" notification (docs/research/2026-10-27-macos-guest-shutdown-via-loginwindow.md).
            guard !Self.holds(parent, name, bytes, mode: mode) else { return false }
            try parent.writeFile(name, mode: mode) { file throws(Failure) in try file.write(bytes) }
            return true
        case .freshSlot:
            preconditionFailure("\(write) is written only below the agent's root")
        }
    }

    /// Whether `name` in `directory` is already what writing `bytes` with `mode` leaves: a regular file of this
    /// process's effective user, with that mode, holding exactly those bytes.
    static func holds(_ directory: borrowing InstallDirectory<Failure>, _ name: String, _ bytes: [UInt8], mode: UInt16)
        -> Bool
    {
        let found = try? directory.contents(of: name) { status in
            status.kind == .regular && status.permissions == UInt32(mode) && status.owner == geteuid()
                && status.size == Int64(bytes.count)
        }
        return found == bytes
    }

    /// Makes `path` and any missing ancestor, the ancestors `0o755`, `path` itself `mode` when this makes it;
    /// anything that `stat`s as a directory will do.
    private func makeDirectory(_ path: String, mode: UInt16) throws(Failure) {
        let components = path.split(separator: "/")
        var current = ""
        for (index, component) in components.enumerated() {
            current += "/" + component
            let target = staged(current)
            var info = stat()
            if stat(target, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw .system(operation: "not a directory:", path: target, errno: ENOTDIR)
                }
                continue
            }
            let wanted = mode_t(index == components.count - 1 ? mode : 0o755)
            guard mkdir(target, wanted) == 0 else { throw .system(operation: "mkdir", path: target, errno: errno) }
            // The umask narrowed what mkdir made.
            guard chmod(target, wanted) == 0 else { throw .system(operation: "chmod", path: target, errno: errno) }
        }
    }

    /// The directory `path` is in, open: any path that opens as a directory will do.
    private func openParent(of path: String) throws(Failure) -> InstallDirectory<Failure> {
        let slash = path.lastIndex(of: "/") ?? path.startIndex
        let directory = String(path[..<slash])
        let target = staged(directory)
        let parent = open(target.isEmpty ? "/" : target, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw .system(operation: "open", path: target, errno: errno) }
        return InstallDirectory(descriptor: parent, path: directory, owner: nil, fileSystem: fileSystem)
    }

    /// `path`'s last component.
    private static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Removes the file or link `path`; a missing one is skipped.
    private func remove(_ path: String) throws(Failure) {
        guard unlink(staged(path)) == 0 || errno == ENOENT else {
            throw .system(operation: "remove", path: staged(path), errno: errno)
        }
    }

    // MARK: Below the root

    /// The agent's root `path`, open and never through a link; nil when it is missing.
    private func openRoot(_ path: String) throws(Failure) -> InstallDirectory<Failure>? {
        do {
            return try InstallDirectory(opening: staged(path), path: path, owner: nil, fileSystem: fileSystem)
        } catch .system(_, _, ENOENT) {
            return nil
        }
    }

    /// The agent's root `path`, made first when it is missing, open and never through a link, and handed to
    /// `owner`.
    private func makeRoot(_ path: String, owner: Owner?) throws(Failure) -> InstallDirectory<Failure> {
        try makeDirectory(path, mode: 0o755)
        let root = try InstallDirectory<Failure>(
            opening: staged(path), path: path, owner: owner, fileSystem: fileSystem)
        try root.handToOwner()
        return root
    }

    /// `path` below `root` (at `rootPath`), as the components below the root.
    private func components(of path: String, below rootPath: String) -> [String] {
        precondition(path.hasPrefix(rootPath + "/"), "\(path) is not below \(rootPath)")
        return path.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
    }

    private func performBelow(
        _ root: borrowing InstallDirectory<Failure>, _ rootPath: String, _ write: InstallPlan.Write, source: Int32?
    ) throws(Failure) {
        switch write {
        case .directory(let path, let mode):
            _ = try root.makeDirectories(components(of: path, below: rootPath), mode: mode)
        case .file(let path, let mode, let text):
            var parts = components(of: path, below: rootPath)
            let name = parts.removeLast()
            let bytes = Array(text.utf8)
            let found = try withDirectory(parts, below: root) { parent throws(Failure) in
                try parent.writeFile(name, mode: mode) { file throws(Failure) in try file.write(bytes) }
            }
            guard found else { throw .system(operation: "open", path: path, errno: ENOENT) }
        case .freshSlot(let installRoot, let payloadName):
            guard let source, let payloadSource else { preconditionFailure("a payload write with no payload open") }
            precondition(installRoot.path == rootPath, "a fresh slot of \(installRoot.path) below \(rootPath)")
            let slot = Self.freshSlotName(in: root)
            let payload = InstallPayloadReader(payloadSource, descriptor: source)
            do {
                let directory = try root.makeDirectories(
                    components(of: installRoot.slot(slot), below: rootPath), mode: 0o755)
                try lander.install(payload, as: payloadName, in: directory)
            }
            let hash = try payload.finish()
            let record = InstallState.fresh(slot: slot, payloadSHA256: lowercaseHex(hash), versionLabel: versionLabel)
            let bytes: [UInt8]
            do { bytes = try record.encoded() } catch { throw .encoding(String(describing: error)) }
            try root.writeFile(InstallRoot.stateName, mode: 0o644) { file throws(Failure) in try file.write(bytes) }
            try root.replaceLink(InstallRoot.rollbackLinkName, target: InstallRoot.slotsName + "/" + slot)
            try root.replaceLink(InstallRoot.currentLinkName, target: InstallRoot.slotsName + "/" + slot)
        }
    }

    /// The slot of `root` that a fresh install fills: the one `current` does not name, so no running peer's slot
    /// is written; ``InstallRoot/firstSlotName`` when it names none.
    static func freshSlotName(in root: borrowing InstallDirectory<Failure>) -> String {
        SlotRoot.slot(linkedFrom: InstallRoot.currentLinkName, in: root.descriptor, on: root.fileSystem)
            .map(InstallState.spare(of:)) ?? InstallRoot.firstSlotName
    }

    /// Runs `body` with the directory `components` name below `root` — `root` itself for none — open.
    ///
    /// - Returns: false, having run nothing, when one of them is missing.
    private func withDirectory(
        _ components: [String], below root: borrowing InstallDirectory<Failure>,
        _ body: (borrowing InstallDirectory<Failure>) throws(Failure) -> Void
    ) throws(Failure) -> Bool {
        guard !components.isEmpty else {
            try body(root)
            return true
        }
        guard let directory = try root.openDirectory(components) else { return false }
        try body(directory)
        return true
    }

    /// Removes `path` below `root`, a directory with everything in it; a missing one is skipped.
    private func removeBelow(_ root: borrowing InstallDirectory<Failure>, _ rootPath: String, _ path: String)
        throws(Failure)
    {
        var parts = components(of: path, below: rootPath)
        let name = parts.removeLast()
        _ = try withDirectory(parts, below: root) { parent throws(Failure) in _ = try parent.removeTree(name) }
    }

    // MARK: Commands

    /// Whether `command` runs: not when commands are off or its path is absent.
    private func willRun(_ command: InstallPlan.Command) -> Bool {
        guard runsCommands else { return false }
        guard let path = command.onlyIfPresent else { return true }
        var info = stat()
        return lstat(staged(path), &info) == 0
    }

    /// Runs `arguments` as ``spawn(_:)`` does, answering its exit status and what it wrote to standard
    /// output.
    public static func capture(_ arguments: [String]) -> (status: Int32, output: [UInt8]) {
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { return (-1, []) }
        var actions = emptyFileActions()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipeEnds[1], 1)
        posix_spawn_file_actions_addclose(&actions, pipeEnds[0])
        let pid = start(arguments, actions: &actions)
        close(pipeEnds[1])
        var output: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(pipeEnds[0], $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            output += buffer[0..<count]
        }
        close(pipeEnds[0])
        guard let pid else { return (-1, []) }
        return (wait(for: pid), output)
    }

    /// Runs `arguments` from `PATH`, with this process's environment, and answers its exit status: -1 when
    /// it could not start, 128 plus the signal that killed it.
    public static func spawn(_ arguments: [String]) -> Int32 {
        guard let pid = start(arguments, actions: nil) else { return -1 }
        return wait(for: pid)
    }

    #if canImport(Darwin)
    /// Darwin's `posix_spawn_file_actions_t` is a pointer, which `posix_spawn_file_actions_init` fills.
    private typealias FileActions = posix_spawn_file_actions_t?
    private static func emptyFileActions() -> FileActions { nil }
    #else
    private typealias FileActions = posix_spawn_file_actions_t
    private static func emptyFileActions() -> FileActions { posix_spawn_file_actions_t() }
    #endif

    private static func start(_ arguments: [String], actions: UnsafePointer<FileActions>?) -> pid_t? {
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid = pid_t()
        let started = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envpBuffer -> Int32 in
                guard let argvBase = argvBuffer.baseAddress, let envpBase = envpBuffer.baseAddress else {
                    return EINVAL
                }
                return posix_spawnp(&pid, arguments[0], actions, nil, argvBase, envpBase)
            }
        }
        return started == 0 ? pid : nil
    }

    private static func wait(for pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return -1 }
        }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
#endif
