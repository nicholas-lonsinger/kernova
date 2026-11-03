#if os(macOS)
import Darwin
import KernovaAgentCore
import KernovaAgentInstall

/// Where one install scope's files go on macOS: the agent's own root, holding its two slots, and the launchd
/// property lists that run it.
///
/// "Just for me" is a per-user LaunchAgent and its rollback check in `~/Library/LaunchAgents`, both bootstrapped
/// into the user's `gui/<uid>` domain. "For everyone" is a LaunchAgent in `/Library/LaunchAgents`, which launchd
/// loads into every user's GUI session at login, plus the system peer and its rollback check in
/// `/Library/LaunchDaemons`, bootstrapped into the `system` domain (launchd.plist(5), FILES; launchctl(1)).
public struct MacInstallLayout: Equatable, Sendable {
    /// `.user` or `.system`.
    public let scope: InstallScope
    /// The agent's own root: `slots/a`, `slots/b`, the `current` link, `state.json`.
    public let root: String
    /// Where the session peer's LaunchAgent, and in the user scope its rollback check, go.
    public let agentsDirectory: String
    /// The GUI domain the session peer is bootstrapped into now, `gui/<uid>`; nil when no user's GUI session
    /// is there to take it, and it starts at the next login.
    public let guiUserID: uid_t?

    /// The same root, as the core lays it out.
    public var installRoot: InstallRoot { InstallRoot(path: root) }

    /// The user scope of the user whose home is `home` and whose GUI domain is `userID`'s.
    public static func user(home: String, userID: uid_t) -> MacInstallLayout {
        MacInstallLayout(
            scope: .user, root: home + "/" + userRootBelowHome, agentsDirectory: home + "/Library/LaunchAgents",
            guiUserID: userID)
    }

    /// The system scope; its session peer bootstrapped now into `consoleUserID`'s GUI domain when one is given.
    public static func system(consoleUserID: uid_t?) -> MacInstallLayout {
        MacInstallLayout(
            scope: .system, root: systemRoot, agentsDirectory: "/Library/LaunchAgents", guiUserID: consoleUserID)
    }

    /// The system scope's root.
    public static let systemRoot = "/Library/Application Support/Kernova/Guest Agent"
    /// The user scope's root, below the user's home.
    public static let userRootBelowHome = "Library/Application Support/Kernova/Guest Agent"
    /// Where the system peer and the system scope's rollback check go.
    public static let daemonsDirectory = "/Library/LaunchDaemons"

    /// The app bundle every slot holds.
    public static let appName = "Kernova Guest Agent.app"
    /// The agent's executable, relative to the app bundle.
    public static let executable = "Contents/MacOS/KernovaMacOSAgent"
    /// The app's bundle identifier, which names every launchd job of its.
    public static let bundleIdentifier = "app.kernova.macosagent"

    /// The executable in the slot `link` points at, `current` or `rollback`.
    public func executable(through link: String) -> String {
        link + "/" + Self.appName + "/" + Self.executable
    }

    // MARK: Jobs

    /// The session peer's job. The user scope keeps the label every earlier per-user install used, so an
    /// install replaces whatever ran under it.
    public var sessionLabel: String {
        scope == .system ? Self.bundleIdentifier + ".session" : Self.bundleIdentifier
    }
    /// The system peer's job.
    public static let systemLabel = bundleIdentifier + ".system"
    /// The rollback check's job.
    public var rollbackLabel: String {
        scope == .system ? Self.systemLabel + ".rollback" : Self.bundleIdentifier + ".rollback"
    }
    /// The job the rollback check kills to revert an update: the one that pulls and switches.
    public var updatingLabel: String { Self.updatingLabel(scope) }
    /// The job that pulls and switches `scope`'s updates: the system peer's, or the user's session peer's.
    public static func updatingLabel(_ scope: InstallScope) -> String {
        scope == .system ? systemLabel : bundleIdentifier
    }

    /// The session peer's property list.
    public var sessionPlist: String { agentsDirectory + "/" + sessionLabel + ".plist" }
    /// The system peer's property list; nil in the user scope.
    public var systemPlist: String? { scope == .system ? Self.daemonsDirectory + "/" + Self.systemLabel + ".plist" : nil }
    /// The rollback check's property list.
    public var rollbackPlist: String {
        (scope == .system ? Self.daemonsDirectory : agentsDirectory) + "/" + rollbackLabel + ".plist"
    }

    /// The domain the jobs of `scope`'s daemons and rollback check go into: `system`, or the user's `gui/<uid>`;
    /// nil for a user scope with no GUI domain.
    var rollbackDomain: String? { scope == .system ? "system" : guiUserID.map { "gui/\($0)" } }
    /// The domain the session peer goes into now; nil when none is there to take it.
    var sessionDomain: String? { guiUserID.map { "gui/\($0)" } }
}

/// Why an install was refused before it started.
public enum MacInstallRefusal: Error, CustomStringConvertible, Equatable {
    /// The request needs a different user than the process runs as.
    case wrongUser(String)
    /// Nothing says where the user's files go.
    case noHome

    public var description: String {
        switch self {
        case .wrongUser(let detail): detail
        case .noHome: "HOME is not set to an absolute path"
        }
    }
}

extension MacInstallLayout {
    /// The layout a request for `scope` installs into, for a process whose effective uid is `effectiveUID`
    /// and whose home is `home`. The user scope refuses root, whose home is not the user's; the system scope
    /// needs root. A dry run, which writes nothing, waives both.
    public static func layout(
        for scope: InstallScope, dryRun: Bool, effectiveUID: uid_t, home: String?, consoleUserID: uid_t?
    ) throws(MacInstallRefusal) -> MacInstallLayout {
        if scope == .system {
            guard dryRun || effectiveUID == 0 else {
                throw .wrongUser("installing for everyone needs root: run it with sudo")
            }
            return .system(consoleUserID: consoleUserID)
        }
        guard dryRun || effectiveUID != 0 else {
            throw .wrongUser("run this as the user the agent is for, not as root; --system installs it for everyone")
        }
        guard let home, home.hasPrefix("/") else { throw .noHome }
        return .user(home: home, userID: effectiveUID)
    }
}
#endif
