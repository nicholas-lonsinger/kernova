#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import CKernovaShims
import KernovaAgentCore
import KernovaDigest
import KernovaPlatformLinux

/// Carries out an ``InstallPlan``: writes each file whole through a rename, so a reader sees the old file or
/// the new one and a running binary is never written over; then runs its commands.
///
/// In the system scope the agent's own root belongs to its account, which can change anything under it,
/// so root never acts on a path there: the installer makes the root itself when it is missing and gives it
/// to the account, and does every write and removal below it as the account, with the account's
/// effective uid and gid on the installing thread alone (`kernova_assume_ids`). A link the account planted then leads nowhere the account
/// could not reach already, and what is written belongs to the account, as `StateDirectory=` would make it.
/// Above the root, and for the unit and autostart directories, any path that `stat`s as a directory will
/// do, as `mkdir -p` takes it; below the root a link where a directory belongs is refused.
struct Installer {
    /// What failed, and where.
    enum Failure: Error, CustomStringConvertible {
        /// A system call on `path` failed with `errno`.
        case system(operation: String, path: String, errno: Int32)
        /// The JSON encoder refused the slot metadata.
        case encoding(String)
        /// A directory could not be removed.
        case removal(path: String, detail: String)
        /// `arguments` could not be started, or exited `status`.
        case command(arguments: [String], status: Int32)
        /// Nothing says where the user's files go.
        case noHome
        /// The request needs a different user than the process runs as.
        case wrongUser(String)
        /// The guest is not running systemd, which every unit the agent installs needs.
        case noSystemd
        /// The account the system scope's root belongs to does not exist.
        case noAccount(String)
        /// The effective ids could not be switched to the account's, or back.
        case identity(errno: Int32)

        var description: String {
            switch self {
            case .system(let operation, let path, let errno):
                "\(operation) \(path): \(String(cString: strerror(errno)))"
            case .encoding(let detail): "cannot encode state.json: \(detail)"
            case .removal(let path, let detail): "cannot remove \(path): \(detail)"
            case .command(let arguments, let status):
                status < 0
                    ? "cannot run \(arguments.joined(separator: " "))"
                    : "\(arguments.joined(separator: " ")) exited \(status)"
            case .noHome: "neither XDG_DATA_HOME and XDG_CONFIG_HOME nor HOME is set to an absolute path"
            case .wrongUser(let detail): detail
            case .noSystemd: "the Kernova guest agent needs systemd, and this system is not running it"
            case .noAccount(let name): "the \(name) account does not exist"
            case .identity(let errno): "cannot switch to the agent's account: \(String(cString: strerror(errno)))"
            }
        }
    }

    /// Prefixed to every path written, removed or checked; empty for the live system.
    let stagingRoot: String
    /// Whether commands run.
    let runsSystemd: Bool
    /// The binary a `.payload` write copies: the installer's own executable.
    let payloadSource: String
    /// The display version the payload reports.
    let versionLabel: String
    /// The account the plan's root belongs to, which every step inside it runs as; nil to run them as the
    /// invoker, as the user scope and a staging root do.
    let account: String?

    /// Refuses unless the guest runs systemd: `runDirectory` exists, as sd_booted(3) tests.
    static func requireSystemd(runDirectory: String = "/run/systemd/system") throws(Failure) {
        var info = stat()
        guard lstat(runDirectory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw .noSystemd }
    }

    /// The environment of the invoking user's systemd manager: the one it searches for units in and runs
    /// the session peer with, so the install's paths are the ones both use.
    static func managerEnvironment() throws(Failure) -> [String: String] {
        let arguments = ["systemctl", "--user", "show-environment"]
        let (status, output) = capture(arguments)
        guard status == 0 else { throw .command(arguments: arguments, status: status) }
        return InstallLayout.environment(parsingShowEnvironment: String(decoding: output, as: UTF8.self))
    }

    /// The layout `request` installs into, for a process whose environment is `environment` and whose
    /// effective uid is `effectiveUID`. User scope refuses root, whose home is not the user's; system scope
    /// needs root. A staging root waives both, since it writes no live system.
    static func layout(
        for request: AgentCommand.InstallRequest, environment: [String: String], effectiveUID: uid_t
    ) throws(Failure) -> InstallLayout {
        let live = request.root == nil
        if request.scope == .system {
            guard !live || effectiveUID == 0 else {
                throw .wrongUser("installing the system service needs root: run it with sudo")
            }
            return .system(root: LinuxIdentity.systemInstallRoot)
        }
        guard !live || effectiveUID != 0 else {
            throw .wrongUser("run this as the user the agent is for, not as root; --system installs the system service")
        }
        guard let root = LinuxIdentity.userInstallRoot(environment: environment),
            let config = InstallLayout.configHome(environment: environment)
        else { throw .noHome }
        return .user(root: root, configHome: config)
    }

    /// The ids the plan's root belongs to.
    private struct Owner {
        var uid: uid_t
        var gid: gid_t
    }

    /// Runs `plan`.
    func run(_ plan: InstallPlan) throws(Failure) {
        // Opened as the invoker: once the effective uid changes, `/proc/self/exe` is no longer readable.
        let source = try openPayload(plan)
        defer { if let source { close(source) } }
        try runCommands(plan.before)
        let owner = try resolveOwner()
        try asOwner(owner) { () throws(Failure) in
            for path in plan.treeRemovals { try remove(path) }
        }
        if !plan.treeWrites.isEmpty { try makeRoot(plan.root, owner: owner) }
        try asOwner(owner) { () throws(Failure) in
            for write in plan.treeWrites { try perform(write, below: plan.root, source: source) }
        }
        for write in plan.writes { try perform(write, below: nil, source: source) }
        for path in plan.removals { try remove(path) }
        if plan.removesRoot {
            try asOwner(owner) { () throws(Failure) in try empty(plan.root) }
            guard rmdir(staged(plan.root)) == 0 || errno == ENOENT else {
                throw .system(operation: "rmdir", path: staged(plan.root), errno: errno)
            }
        }
        try runCommands(plan.after)
    }

    private func openPayload(_ plan: InstallPlan) throws(Failure) -> Int32? {
        guard plan.treeWrites.contains(where: { if case .payload = $0 { true } else { false } }) else { return nil }
        let source = open(payloadSource, O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw .system(operation: "open", path: payloadSource, errno: errno) }
        return source
    }

    private func resolveOwner() throws(Failure) -> Owner? {
        guard let account else { return nil }
        guard let entry = getpwnam(account) else { throw .noAccount(account) }
        return Owner(uid: entry.pointee.pw_uid, gid: entry.pointee.pw_gid)
    }

    /// Runs `body` on this thread with `owner`'s effective ids, then returns to the invoker's; with no owner,
    /// as the invoker. `body` is synchronous, so nothing else runs on the thread in between.
    private func asOwner(_ owner: Owner?, _ body: () throws(Failure) -> Void) throws(Failure) {
        guard let owner else { return try body() }
        let uid = geteuid()
        let gid = getegid()
        var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
        guard getgroups(Int32(groups.count), &groups) >= 0 else { throw .identity(errno: errno) }
        guard kernova_assume_ids(owner.uid, owner.gid) == 0 else { throw .identity(errno: errno) }
        var outcome: Failure?
        do throws(Failure) { try body() } catch { outcome = error }
        guard kernova_restore_ids(uid, gid, groups, groups.count) == 0 else { throw .identity(errno: errno) }
        if let outcome { throw outcome }
    }

    private func perform(_ write: InstallPlan.Write, below root: String?, source: Int32?) throws(Failure) {
        switch write {
        case .directory(let path, let mode):
            try makeDirectory(path, mode: mode, below: root)
        case .file(let path, let mode, let text):
            try writeFile(path, mode: mode) { descriptor throws(Failure) in
                try writeAll(Array(text.utf8), to: descriptor, path: path)
            }
        case .payload(let binary, let state):
            guard let source else { throw .system(operation: "open", path: payloadSource, errno: EBADF) }
            let hash = try copyPayload(from: source, to: binary)
            let record = InstallState.fresh(payloadSHA256: lowercaseHex(hash), versionLabel: versionLabel)
            let bytes: [UInt8]
            do { bytes = try record.encoded() } catch { throw .encoding(String(describing: error)) }
            try writeFile(state, mode: 0o644) { descriptor throws(Failure) in
                try writeAll(bytes, to: descriptor, path: state)
            }
        case .link(let path, let target):
            try replaceLink(path, target: target)
        }
    }

    // MARK: Files

    private func staged(_ path: String) -> String { stagingRoot + path }

    /// Makes `path` and any missing ancestor, the ancestors `0o755`, `path` itself `mode` when this makes it.
    /// Components at or above `root`, or all of them with no root, may be anything that `stat`s as a
    /// directory; one below `root` must be a directory itself, never a link.
    private func makeDirectory(_ path: String, mode: UInt16, below root: String?) throws(Failure) {
        let components = path.split(separator: "/")
        var current = ""
        for (index, component) in components.enumerated() {
            current += "/" + component
            let target = staged(current)
            let followsLinks = root.map { !current.hasPrefix($0 + "/") } ?? true
            var info = stat()
            if (followsLinks ? stat(target, &info) : lstat(target, &info)) == 0 {
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

    /// Makes `root` when it is missing and hands it to `owner`: the one step the invoker takes there.
    private func makeRoot(_ root: String, owner: Owner?) throws(Failure) {
        try makeDirectory(root, mode: 0o755, below: nil)
        guard let owner else { return }
        let target = staged(root)
        let descriptor = open(target, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw .system(operation: "open", path: target, errno: errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .system(operation: "stat", path: target, errno: errno) }
        if info.st_uid != owner.uid || info.st_gid != owner.gid {
            guard fchown(descriptor, owner.uid, owner.gid) == 0 else {
                throw .system(operation: "chown", path: target, errno: errno)
            }
        }
    }

    /// Writes `path` whole: `fill` writes a new file beside it, which then replaces it.
    private func writeFile(
        _ path: String, mode: UInt16, _ fill: (Int32) throws(Failure) -> Void
    ) throws(Failure) {
        let target = staged(path)
        let temporary = target + ".kernova-new"
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        guard descriptor >= 0 else { throw .system(operation: "create", path: temporary, errno: errno) }
        do throws(Failure) {
            try fill(descriptor)
            guard fchmod(descriptor, mode_t(mode)) == 0 else {
                throw .system(operation: "chmod", path: temporary, errno: errno)
            }
        } catch {
            close(descriptor)
            unlink(temporary)
            throw error
        }
        guard close(descriptor) == 0 else {
            unlink(temporary)
            throw .system(operation: "close", path: temporary, errno: errno)
        }
        guard rename(temporary, target) == 0 else {
            let failure = errno
            unlink(temporary)
            throw .system(operation: "rename onto", path: target, errno: failure)
        }
    }

    /// Copies the file open at `source` to `path`, mode `0o755`, answering its SHA-256.
    private func copyPayload(from source: Int32, to path: String) throws(Failure) -> [UInt8] {
        var hasher = SHA256()
        try writeFile(path, mode: 0o755) { descriptor throws(Failure) in
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var offset: off_t = 0
            while true {
                let count = buffer.withUnsafeMutableBytes { pread(source, $0.baseAddress, $0.count, offset) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw .system(operation: "read", path: payloadSource, errno: errno) }
                guard count > 0 else { return }
                let piece = Array(buffer[0..<count])
                hasher.update(piece)
                try writeAll(piece, to: descriptor, path: path)
                offset += off_t(count)
            }
        }
        return hasher.finalize()
    }

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32, path: String) throws(Failure) {
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw .system(operation: "write", path: path, errno: errno) }
            offset += count
        }
    }

    /// Points `path` at `target`, replacing whatever link is there in one rename.
    private func replaceLink(_ path: String, target: String) throws(Failure) {
        let staged = staged(path)
        let temporary = staged + ".kernova-new"
        unlink(temporary)
        guard symlink(target, temporary) == 0 else {
            throw .system(operation: "symlink", path: temporary, errno: errno)
        }
        guard rename(temporary, staged) == 0 else {
            let failure = errno
            unlink(temporary)
            throw .system(operation: "rename onto", path: staged, errno: failure)
        }
    }

    /// Removes `path`, a directory with everything in it; a missing one is skipped.
    private func remove(_ path: String) throws(Failure) {
        let target = staged(path)
        var info = stat()
        guard lstat(target, &info) == 0 else {
            guard errno == ENOENT else { throw .system(operation: "stat", path: target, errno: errno) }
            return
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            do {
                try FileManager.default.removeItem(atPath: target)
            } catch {
                throw .removal(path: target, detail: String(describing: error))
            }
        } else if unlink(target) != 0 {
            throw .system(operation: "remove", path: target, errno: errno)
        }
    }

    /// Removes everything in the directory `root`, leaving it; a missing one is skipped.
    private func empty(_ root: String) throws(Failure) {
        let target = staged(root)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: target)
        } catch {
            var info = stat()
            guard lstat(target, &info) == 0 else { return }
            throw .removal(path: target, detail: String(describing: error))
        }
        for name in names { try remove(root + "/" + name) }
    }

    // MARK: Commands

    private func runCommands(_ commands: [InstallPlan.Command]) throws(Failure) {
        guard runsSystemd else { return }
        for command in commands {
            if let path = command.onlyIfPresent {
                var info = stat()
                guard lstat(staged(path), &info) == 0 else { continue }
            }
            let status = Self.spawn(command.arguments)
            guard status == 0 else { throw .command(arguments: command.arguments, status: status) }
        }
    }

    /// Runs `arguments` as ``spawn(_:)`` does, answering its exit status and what it wrote to standard
    /// output.
    static func capture(_ arguments: [String]) -> (status: Int32, output: [UInt8]) {
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { return (-1, []) }
        var actions = posix_spawn_file_actions_t()
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
    static func spawn(_ arguments: [String]) -> Int32 {
        guard let pid = start(arguments, actions: nil) else { return -1 }
        return wait(for: pid)
    }

    private static func start(_ arguments: [String], actions: UnsafePointer<posix_spawn_file_actions_t>?) -> pid_t? {
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
