#if os(macOS)
import Darwin
import Foundation
import KernovaAgentCore
import KernovaAgentInstall
import KernovaDigest
import KernovaKit
import MachO

/// Who this macOS agent process is: everything its Hello claims except the role's session state.
///
/// The payload hash is the one the install's slot metadata records for the slot the process runs from: a
/// format-4 payload is a container the slot's app bundle was landed from, so, unlike the Linux agent's single
/// executable, nothing on disk can be hashed back into it. An agent run from no slot, as a development build
/// run in place is, claims no hash and no scope.
public enum DarwinIdentity {
    /// The claim of an agent in `role` labelled `versionLabel`.
    public static func current(role: PeerRole, versionLabel: String) -> PeerClaim {
        let executable = executablePath()
        let running = executable.flatMap(slot(ofExecutable:))
        var hash = Data()
        if let running, let hex = try? SlotRoot(path: running.root).payloadSHA256(ofSlot: running.slot),
            let bytes = bytes(fromHex: hex)
        {
            hash = Data(bytes)
        }
        return PeerClaim(
            role: role,
            scope: executable.map { executable in
                scope(ofExecutable: executable, systemRoot: canonicalPath(MacInstallLayout.systemRoot)) { path in
                    var info = stat()
                    return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                }
            } ?? .unspecified,
            os: .macOS, osVersion: osVersion, osBuild: osBuild, architecture: architecture, payloadHash: hash,
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

    /// The running system's ``MacOSVersion``.
    ///
    /// Reads the decomposed `operatingSystemVersion`: `operatingSystemVersionString` is human-readable,
    /// localized, and documented by Apple as not for parsing.
    public static var osVersion: String {
        MacOSVersion(ProcessInfo.processInfo.operatingSystemVersion).description
    }

    /// The OS build, `kern.osversion`: "24D70".
    public static var osBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// This process's executable, every symlink resolved: launchd runs it through the install's `current`
    /// link, which `realpath(3)` resolves to the slot.
    public static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return canonicalPath(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// Where the agent is installed, judged by the install layout `executable` sits in, never by an
    /// environment variable: a slot of a root holding `state.json` (`isFile` answers for a path) is `.system`
    /// when the root is `systemRoot` and `.user` anywhere else. Anything else is `.unspecified`, as a
    /// development build run in place is. Every path is canonical, as realpath(3) gives it; a nil system root
    /// does not exist.
    public static func scope(ofExecutable executable: String, systemRoot: String?, isFile: (String) -> Bool)
        -> InstallScope
    {
        guard let slot = slot(ofExecutable: executable), isFile(slot.root + "/state.json") else { return .unspecified }
        return slot.root == systemRoot ? .system : .user
    }

    /// The install root and slot `executable` sits in when its path has the slot layout's shape,
    /// `<root>/slots/<slot>/Kernova Guest Agent.app/Contents/MacOS/KernovaMacOSAgent`; nil otherwise.
    public static func slot(ofExecutable executable: String) -> (root: String, slot: String)? {
        let suffix = "/" + MacInstallLayout.appName + "/" + MacInstallLayout.executable
        guard executable.hasSuffix(suffix) else { return nil }
        var components = executable.dropLast(suffix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return nil }
        let slot = String(components.removeLast())
        guard components.removeLast() == "slots" else { return nil }
        let root = components.joined(separator: "/")
        guard !root.isEmpty, !slot.isEmpty else { return nil }
        return (root, slot)
    }

    /// The install root and slot this process's executable sits in; nil when it sits in none.
    public static func runningSlot() -> (root: String, slot: String)? {
        executablePath().flatMap(slot(ofExecutable:))
    }

    /// `path` as realpath(3) resolves it; nil when it does not exist.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
#endif
