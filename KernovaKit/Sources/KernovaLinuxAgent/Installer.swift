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

    /// Runs `plan`.
    func run(_ plan: InstallPlan) throws(Failure) {
        try runCommands(plan.before)
        for write in plan.writes {
            switch write {
            case .directory(let path, let mode):
                try makeDirectory(path, mode: mode)
            case .file(let path, let mode, let text):
                try writeFile(path, mode: mode) { descriptor throws(Failure) in
                    try writeAll(Array(text.utf8), to: descriptor, path: path)
                }
            case .payload(let binary, let state):
                let hash = try copyPayload(to: binary, mode: 0o755)
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
        for path in plan.removals { try remove(path) }
        try runCommands(plan.after)
    }

    // MARK: Files

    private func staged(_ path: String) -> String { stagingRoot + path }

    /// Makes `path` and any missing ancestor, the ancestors `0o755`, `path` itself `mode` when this makes it.
    private func makeDirectory(_ path: String, mode: UInt16) throws(Failure) {
        let components = path.split(separator: "/")
        var current = ""
        for (index, component) in components.enumerated() {
            current += "/" + component
            let target = staged(current)
            var info = stat()
            if lstat(target, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw .system(operation: "not a directory:", path: target, errno: ENOTDIR)
                }
                continue
            }
            let wanted = mode_t(index == components.count - 1 ? mode : 0o755)
            guard mkdir(target, wanted) == 0 || errno == EEXIST else {
                throw .system(operation: "mkdir", path: target, errno: errno)
            }
            // The umask narrowed what mkdir made.
            guard chmod(target, wanted) == 0 else { throw .system(operation: "chmod", path: target, errno: errno) }
        }
    }

    /// Writes `path` whole: `fill` writes a new file beside it, which then replaces it.
    private func writeFile(
        _ path: String, mode: UInt16, _ fill: (Int32) throws(Failure) -> Void
    ) throws(Failure) {
        let target = staged(path)
        let temporary = target + ".kernova-new"
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(mode))
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

    /// Copies ``payloadSource`` to `path`, answering its SHA-256.
    private func copyPayload(to path: String, mode: UInt16) throws(Failure) -> [UInt8] {
        let source = open(payloadSource, O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw .system(operation: "open", path: payloadSource, errno: errno) }
        defer { close(source) }
        var hasher = SHA256()
        try writeFile(path, mode: mode) { descriptor throws(Failure) in
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw .system(operation: "read", path: payloadSource, errno: errno) }
                guard count > 0 else { return }
                let piece = Array(buffer[0..<count])
                hasher.update(piece)
                try writeAll(piece, to: descriptor, path: path)
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

    /// Runs `arguments` from `PATH`, with this process's environment, and answers its exit status: -1 when
    /// it could not start, 128 plus the signal that killed it.
    static func spawn(_ arguments: [String]) -> Int32 {
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
                return posix_spawnp(&pid, arguments[0], nil, nil, argvBase, envpBase)
            }
        }
        guard started == 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return -1 }
        }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
#endif
