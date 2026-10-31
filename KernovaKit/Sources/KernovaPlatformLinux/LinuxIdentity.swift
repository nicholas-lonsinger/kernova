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

/// Who this agent process is: everything its Hello claims except the role's session state, computed from
/// the running system and its own executable, never read from metadata.
public enum LinuxIdentity {
    /// The system peer's install root.
    public static let systemInstallRoot = "/opt/kernova-agent"

    /// The claim of an agent in `role` labelled `versionLabel`, run from the executable `/proc/self/exe`
    /// names. Its payload hash is that file's SHA-256.
    public static func current(role: PeerRole, versionLabel: String) throws(LinuxIdentityError) -> PeerClaim {
        guard let executable = canonicalPath("/proc/self/exe") else { throw .executableUnreadable(errno) }
        let release = osRelease()
        return PeerClaim(
            role: role,
            scope: scope(ofExecutable: executable, systemRoot: canonicalPath(systemInstallRoot)) { path in
                var info = stat()
                return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            },
            os: .linux,
            osVersion: release["VERSION_ID"] ?? "", osBuild: kernelRelease(), osDistribution: distribution(release),
            architecture: architecture, payloadHash: Data(try sha256(ofFileAt: "/proc/self/exe")),
            versionLabel: versionLabel)
    }

    /// The architecture this binary runs on.
    public static var architecture: Architecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unspecified
        #endif
    }

    /// Where the agent is installed, judged by the install layout `executable` sits in, never by an
    /// environment variable: a slot, `<root>/slots/<slot>/kernova-agent`, of a root holding `state.json`
    /// (`isFile` answers for a path) is `.system` when the root is `systemRoot` (`/opt/kernova-agent`)
    /// and `.user` anywhere else. Anything else is `.unspecified`, as a development build run in place is.
    /// Every path is canonical, as realpath(3) gives it, since `/proc/self/exe` resolves every symlink; a nil
    /// system root does not exist.
    public static func scope(ofExecutable executable: String, systemRoot: String?, isFile: (String) -> Bool)
        -> InstallScope
    {
        var components = executable.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 5, components.removeLast() == "kernova-agent" else { return .unspecified }
        components.removeLast()
        guard components.removeLast() == "slots" else { return .unspecified }
        let root = components.joined(separator: "/")
        guard !root.isEmpty, isFile(root + "/state.json") else { return .unspecified }
        return root == systemRoot ? .system : .user
    }

    /// The user install root, `${XDG_DATA_HOME:-$HOME/.local/share}/kernova-agent`; nil with neither set.
    /// An empty or relative `XDG_DATA_HOME` is ignored, as the XDG Base Directory specification says.
    public static func userInstallRoot(environment: [String: String]) -> String? {
        if let data = environment["XDG_DATA_HOME"], data.hasPrefix("/") { return data + "/kernova-agent" }
        guard let home = environment["HOME"], home.hasPrefix("/") else { return nil }
        return home + "/.local/share/kernova-agent"
    }

    /// The os-release(5) fields: `/etc/os-release`, or `/usr/lib/os-release` when that is absent; empty
    /// when neither can be read.
    public static func osRelease() -> [String: String] {
        for path in ["/etc/os-release", "/usr/lib/os-release"] {
            if let text = readText(path) { return osRelease(parsing: text) }
        }
        return [:]
    }

    /// The distribution os-release(5) `fields` name: `ID`, or `linux` when it is unset, as os-release(5)
    /// defines.
    public static func distribution(_ fields: [String: String]) -> String {
        guard let id = fields["ID"], !id.isEmpty else { return "linux" }
        return id
    }

    /// Parses os-release(5) text: one `KEY=value` per line, the value bare or in single or double quotes
    /// with shell escapes inside double quotes. Comments, blank lines and lines without a valid key are
    /// skipped; a later line wins.
    public static func osRelease(parsing text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals]
            guard let first = key.first, first.isLetter || first == "_",
                key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
            else { continue }
            fields[String(key)] = unquote(trimmed[trimmed.index(after: equals)...])
        }
        return fields
    }

    /// `uname(2)`'s release: the running kernel's version.
    public static func kernelRelease() -> String {
        var name = utsname()
        guard uname(&name) == 0 else { return "" }
        return withUnsafeBytes(of: &name.release) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// The SHA-256 of the file at `path`, read in 1 MiB pieces.
    public static func sha256(ofFileAt path: String) throws(LinuxIdentityError) -> [UInt8] {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw .executableUnreadable(errno) }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw .executableUnreadable(errno) }
            guard count > 0 else { return hasher.finalize() }
            buffer.withUnsafeBytes { hasher.update(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
    }

    private static func unquote(_ value: Substring) -> String {
        var value = value
        while let last = value.last, last == " " || last == "\t" || last == "\r" { value.removeLast() }
        guard let quote = value.first, quote == "\"" || quote == "'", value.count >= 2, value.last == quote else {
            return String(value)
        }
        let inner = value.dropFirst().dropLast()
        guard quote == "\"" else { return String(inner) }
        var result = ""
        var escaped = false
        for character in inner {
            if escaped {
                if !"\"\\`$".contains(character) { result.append("\\") }
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The whole file at `path` as UTF-8 text; nil when it cannot be read.
    static func readText(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            guard count > 0 else { return String(decoding: bytes, as: UTF8.self) }
            bytes += buffer[0..<count]
        }
    }
}

/// Why the agent could not compute its identity.
public enum LinuxIdentityError: Error, Sendable, Equatable {
    /// Its own executable could not be resolved or read; the error number says why.
    case executableUnreadable(Int32)
}
#endif
