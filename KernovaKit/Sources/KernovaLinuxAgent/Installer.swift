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

import KernovaAgentCore
import KernovaDigest
import KernovaPlatformLinux

/// Carries out an ``InstallPlan``: writes each file whole through a rename, so a reader sees the old file or
/// the new one and a running binary is never written over; then runs its commands.
///
/// The agent's own root may belong to an account other than the installer's, which can change anything under
/// it: the system scope's account. So the installer never resolves a name under the root by path. It makes the
/// root itself when it is missing, opens it without following a link, and reaches everything below through
/// descriptors: each directory opened `O_DIRECTORY | O_NOFOLLOW` relative to its parent, each file created
/// `O_EXCL | O_NOFOLLOW` beside its destination and renamed onto it, each removal an `unlinkat` relative to its
/// directory, and each owner and mode set on the descriptor. A link the account planted is refused or removed,
/// never followed, and what is written belongs to the account, as `StateDirectory=` would make it. Above the
/// root, and for the unit and autostart directories, any path that `stat`s as a directory will do, as
/// `mkdir -p` takes it.
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
    /// The account the plan's root and everything in it belong to; nil for the invoker, as in the user scope
    /// and a staging root.
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
        let source = try openPayload(plan)
        defer { if let source { close(source) } }
        try runCommands(plan.before)
        let owner = try resolveOwner()
        if let root = try openRoot(plan.root, creating: false, owner: nil) {
            defer { close(root) }
            for path in plan.treeRemovals { try removeBelow(root, plan.root, path) }
        }
        if !plan.treeWrites.isEmpty {
            guard let root = try openRoot(plan.root, creating: true, owner: owner) else { return }
            defer { close(root) }
            for write in plan.treeWrites { try performBelow(root, plan.root, write, owner: owner, source: source) }
        }
        for write in plan.writes { try perform(write, source: source) }
        for path in plan.removals { try remove(path) }
        if plan.removesRoot, let root = try openRoot(plan.root, creating: false, owner: nil) {
            do throws(Failure) { try empty(root, path: plan.root) } catch {
                close(root)
                throw error
            }
            close(root)
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

    // MARK: Outside the root

    private func staged(_ path: String) -> String { stagingRoot + path }

    private func perform(_ write: InstallPlan.Write, source: Int32?) throws(Failure) {
        switch write {
        case .directory(let path, let mode):
            try makeDirectory(path, mode: mode)
        case .file(let path, let mode, let text):
            let (parent, name) = try openParent(of: path)
            defer { close(parent) }
            try writeFile(in: parent, name, path: path, mode: mode, owner: nil) { descriptor throws(Failure) in
                try writeAll(Array(text.utf8), to: descriptor, path: path)
            }
        case .payload, .link:
            preconditionFailure("\(write) is written only below the agent's root")
        }
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

    /// The directory `path` is in, open, and `path`'s last component.
    private func openParent(of path: String) throws(Failure) -> (Int32, String) {
        let slash = path.lastIndex(of: "/") ?? path.startIndex
        let directory = staged(String(path[..<slash]))
        let parent = open(directory.isEmpty ? "/" : directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw .system(operation: "open", path: directory, errno: errno) }
        return (parent, String(path[path.index(after: slash)...]))
    }

    /// Removes the file or link `path`; a missing one is skipped.
    private func remove(_ path: String) throws(Failure) {
        guard unlink(staged(path)) == 0 || errno == ENOENT else {
            throw .system(operation: "remove", path: staged(path), errno: errno)
        }
    }

    // MARK: Below the root

    /// The agent's root `path`, open and never through a link: made first when it is missing and `creating`
    /// is set, and handed to `owner`. Nil when it is missing and nothing makes it.
    private func openRoot(_ path: String, creating: Bool, owner: Owner?) throws(Failure) -> Int32? {
        if creating { try makeDirectory(path, mode: 0o755) }
        let root = open(staged(path), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            guard errno == ENOENT, !creating else { throw .system(operation: "open", path: staged(path), errno: errno) }
            return nil
        }
        do throws(Failure) { try own(root, by: owner, path: path) } catch {
            close(root)
            throw error
        }
        return root
    }

    /// `path` below `root` (at `rootPath`), as the components below the root.
    private func components(of path: String, below rootPath: String) -> [String] {
        precondition(path.hasPrefix(rootPath + "/"), "\(path) is not below \(rootPath)")
        return path.dropFirst(rootPath.count + 1).split(separator: "/").map(String.init)
    }

    /// The directory the components name below `root`, open; each one made `mode` and handed to `owner` when it
    /// is missing and `creating` is set, and nil when one is missing and not. A link where a directory belongs
    /// is refused.
    private func openDirectory(
        _ components: [String], below root: Int32, path: String, creating: Bool, mode: UInt16, owner: Owner?
    ) throws(Failure) -> Int32? {
        var current = dup(root)
        guard current >= 0 else { throw .system(operation: "dup", path: path, errno: errno) }
        for component in components {
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, creating {
                guard mkdirat(current, component, mode_t(mode)) == 0 || errno == EEXIST else {
                    let failure = errno
                    close(current)
                    throw .system(operation: "mkdir", path: path, errno: failure)
                }
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next >= 0 {
                    // The umask narrowed what mkdirat made.
                    guard fchmod(next, mode_t(mode)) == 0 else {
                        let failure = errno
                        close(next)
                        close(current)
                        throw .system(operation: "chmod", path: path, errno: failure)
                    }
                    do throws(Failure) { try own(next, by: owner, path: path) } catch {
                        close(next)
                        close(current)
                        throw error
                    }
                }
            }
            let failure = errno
            close(current)
            guard next >= 0 else {
                guard failure == ENOENT, !creating else {
                    throw .system(operation: "open", path: path, errno: failure == ELOOP ? ENOTDIR : failure)
                }
                return nil
            }
            current = next
        }
        return current
    }

    private func own(_ descriptor: Int32, by owner: Owner?, path: String) throws(Failure) {
        guard let owner else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .system(operation: "stat", path: path, errno: errno) }
        guard info.st_uid != owner.uid || info.st_gid != owner.gid else { return }
        guard fchown(descriptor, owner.uid, owner.gid) == 0 else {
            throw .system(operation: "chown", path: path, errno: errno)
        }
    }

    private func performBelow(
        _ root: Int32, _ rootPath: String, _ write: InstallPlan.Write, owner: Owner?, source: Int32?
    ) throws(Failure) {
        switch write {
        case .directory(let path, let mode):
            let directory = try openDirectory(
                components(of: path, below: rootPath), below: root, path: path, creating: true, mode: mode,
                owner: owner)
            if let directory { close(directory) }
        case .file(let path, let mode, let text):
            try withParent(of: path, below: root, rootPath, owner: owner) { parent, name throws(Failure) in
                try writeFile(in: parent, name, path: path, mode: mode, owner: owner) { descriptor throws(Failure) in
                    try writeAll(Array(text.utf8), to: descriptor, path: path)
                }
            }
        case .payload(let binary, let state):
            guard let source else { throw .system(operation: "open", path: payloadSource, errno: EBADF) }
            var hash: [UInt8] = []
            try withParent(of: binary, below: root, rootPath, owner: owner) { parent, name throws(Failure) in
                hash = try copyPayload(from: source, into: parent, name, path: binary, owner: owner)
            }
            let record = InstallState.fresh(payloadSHA256: lowercaseHex(hash), versionLabel: versionLabel)
            let bytes: [UInt8]
            do { bytes = try record.encoded() } catch { throw .encoding(String(describing: error)) }
            try withParent(of: state, below: root, rootPath, owner: owner) { parent, name throws(Failure) in
                try writeFile(in: parent, name, path: state, mode: 0o644, owner: owner) { descriptor throws(Failure) in
                    try writeAll(bytes, to: descriptor, path: state)
                }
            }
        case .link(let path, let target):
            try withParent(of: path, below: root, rootPath, owner: owner) { parent, name throws(Failure) in
                try replaceLink(in: parent, name, path: path, target: target, owner: owner)
            }
        }
    }

    /// Runs `body` with the directory `path` is in, below `root`, open, and `path`'s last component. That
    /// directory must exist.
    private func withParent(
        of path: String, below root: Int32, _ rootPath: String, owner: Owner?,
        _ body: (Int32, String) throws(Failure) -> Void
    ) throws(Failure) {
        var parts = components(of: path, below: rootPath)
        let name = parts.removeLast()
        guard
            let parent = try openDirectory(
                parts, below: root, path: path, creating: false, mode: 0o755, owner: owner)
        else { throw .system(operation: "open", path: path, errno: ENOENT) }
        defer { close(parent) }
        try body(parent, name)
    }

    /// Removes `path` below `root`, a directory with everything in it; a missing one is skipped.
    private func removeBelow(_ root: Int32, _ rootPath: String, _ path: String) throws(Failure) {
        var parts = components(of: path, below: rootPath)
        let name = parts.removeLast()
        guard
            let parent = try openDirectory(
                parts, below: root, path: path, creating: false, mode: 0o755, owner: nil)
        else { return }
        defer { close(parent) }
        try removeEntry(name, in: parent, path: path)
    }

    /// Removes the entry `name` in `directory`: a file or link unlinked, never followed, and a directory
    /// emptied through its own descriptor and removed.
    private func removeEntry(_ name: String, in directory: Int32, path: String) throws(Failure) {
        if unlinkat(directory, name, 0) == 0 || errno == ENOENT { return }
        guard errno == EISDIR else { throw .system(operation: "remove", path: path, errno: errno) }
        let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw .system(operation: "open", path: path, errno: errno) }
        do throws(Failure) { try empty(child, path: path) } catch {
            close(child)
            throw error
        }
        close(child)
        guard unlinkat(directory, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw .system(operation: "rmdir", path: path, errno: errno)
        }
    }

    /// Removes everything in the open `directory`, leaving it.
    private func empty(_ directory: Int32, path: String) throws(Failure) {
        let listing = dup(directory)
        guard listing >= 0 else { throw .system(operation: "list", path: path, errno: errno) }
        guard let stream = fdopendir(listing) else {
            let failure = errno
            close(listing)
            throw .system(operation: "list", path: path, errno: failure)
        }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        closedir(stream)
        for name in names { try removeEntry(name, in: directory, path: path + "/" + name) }
    }

    // MARK: Files

    /// Writes `name` in `directory` whole: `fill` writes a new file beside it, `name.kernova-new`, which then
    /// replaces it in one rename, owned by `owner` and with `mode`.
    ///
    /// The new file is made in the destination's own directory, never elsewhere and moved: a rename keeps the
    /// SELinux label a file was created with, and only one created in place takes the directory's, so a binary
    /// made anywhere else would land unexecutable. Every writer of the agent's slots follows this rule.
    private func writeFile(
        in directory: Int32, _ name: String, path: String, mode: UInt16, owner: Owner?,
        _ fill: (Int32) throws(Failure) -> Void
    ) throws(Failure) {
        let temporary = name + ".kernova-new"
        guard unlinkat(directory, temporary, 0) == 0 || errno == ENOENT else {
            throw .system(operation: "remove", path: path + ".kernova-new", errno: errno)
        }
        let descriptor = openat(
            directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(mode))
        guard descriptor >= 0 else { throw .system(operation: "create", path: path + ".kernova-new", errno: errno) }
        do throws(Failure) {
            try fill(descriptor)
            guard fchmod(descriptor, mode_t(mode)) == 0 else {
                throw .system(operation: "chmod", path: path + ".kernova-new", errno: errno)
            }
            try own(descriptor, by: owner, path: path + ".kernova-new")
        } catch {
            close(descriptor)
            unlinkat(directory, temporary, 0)
            throw error
        }
        guard close(descriptor) == 0 else {
            unlinkat(directory, temporary, 0)
            throw .system(operation: "close", path: path + ".kernova-new", errno: errno)
        }
        guard renameat(directory, temporary, directory, name) == 0 else {
            let failure = errno
            unlinkat(directory, temporary, 0)
            throw .system(operation: "rename onto", path: path, errno: failure)
        }
    }

    /// Copies the file open at `source` to `name` in `directory`, mode `0o755`, answering its SHA-256.
    private func copyPayload(
        from source: Int32, into directory: Int32, _ name: String, path: String, owner: Owner?
    ) throws(Failure) -> [UInt8] {
        var hasher = SHA256()
        try writeFile(in: directory, name, path: path, mode: 0o755, owner: owner) { descriptor throws(Failure) in
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

    /// Points `name` in `directory` at `target`, replacing whatever entry is there in one rename.
    private func replaceLink(
        in directory: Int32, _ name: String, path: String, target: String, owner: Owner?
    ) throws(Failure) {
        let temporary = name + ".kernova-new"
        guard unlinkat(directory, temporary, 0) == 0 || errno == ENOENT else {
            throw .system(operation: "remove", path: path + ".kernova-new", errno: errno)
        }
        guard symlinkat(target, directory, temporary) == 0 else {
            throw .system(operation: "symlink", path: path + ".kernova-new", errno: errno)
        }
        if let owner, fchownat(directory, temporary, owner.uid, owner.gid, AT_SYMLINK_NOFOLLOW) != 0 {
            let failure = errno
            unlinkat(directory, temporary, 0)
            throw .system(operation: "chown", path: path + ".kernova-new", errno: failure)
        }
        guard renameat(directory, temporary, directory, name) == 0 else {
            let failure = errno
            unlinkat(directory, temporary, 0)
            throw .system(operation: "rename onto", path: path, errno: failure)
        }
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
