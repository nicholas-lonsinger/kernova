#if os(macOS)
import Darwin
import KernovaAgentCore
import KernovaAgentInstall

/// What one scope's install puts in launchd's hands: the property lists (``LaunchdPlists``), and the
/// `launchctl` commands around them.
///
/// Every job is stopped with `stopTool`'s `stop-service`, which returns once launchd has let the job go:
/// `launchctl bootout` returns before a job that is still exiting is gone, and bootstrapping its label again
/// meanwhile fails. Each property list is bootstrapped into its own domain: the user scope's into the user's
/// `gui/<uid>`, the system scope's daemons into `system` and its LaunchAgent into the console user's
/// `gui/<uid>` when there is one, every other user's at their next login.
public struct LaunchdJobs: ServiceDefinitions {
    /// The scope's files.
    public let layout: MacInstallLayout
    /// The agent executable whose `stop-service` stops a job and waits for launchd to let it go.
    public let stopTool: String

    /// The jobs of `layout`, stopped through `stopTool`.
    public init(_ layout: MacInstallLayout, stopTool: String) {
        self.layout = layout
        self.stopTool = stopTool
    }

    /// The property lists, each directory first.
    public var writes: [InstallPlan.Write] {
        var writes: [InstallPlan.Write] = [.directory(path: layout.agentsDirectory, mode: 0o755)]
        writes.append(.file(path: layout.sessionPlist, mode: 0o644, text: LaunchdPlists.session(layout)))
        if let system = layout.systemPlist {
            writes.append(.directory(path: MacInstallLayout.daemonsDirectory, mode: 0o755))
            writes.append(.file(path: system, mode: 0o644, text: LaunchdPlists.system(layout)))
        }
        writes.append(.file(path: layout.rollbackPlist, mode: 0o644, text: LaunchdPlists.rollback(layout)))
        return writes
    }

    /// Stops the rollback check first, so none judges the root while it is rewritten, then the peers.
    public var beforeInstall: [InstallPlan.Command] { stops }

    /// Loads the rollback check, then the peers, which start at once (`RunAtLoad`).
    public var afterInstall: [InstallPlan.Command] {
        var commands: [InstallPlan.Command] = []
        if let domain = layout.rollbackDomain { commands.append(bootstrap(domain, layout.rollbackPlist)) }
        if let system = layout.systemPlist { commands.append(bootstrap("system", system)) }
        if let domain = layout.sessionDomain { commands.append(bootstrap(domain, layout.sessionPlist)) }
        return commands
    }

    /// Stops the rollback check, then the peers.
    public var beforeUninstall: [InstallPlan.Command] { stops }

    /// None: the jobs went with their stops.
    public var afterUninstall: [InstallPlan.Command] { [] }

    /// None: launchd reads a loaded job's property list only when it loads it, at the next login or boot.
    public var afterRefresh: [InstallPlan.Command] { [] }

    private var stops: [InstallPlan.Command] {
        var commands: [InstallPlan.Command] = []
        if let domain = layout.rollbackDomain { commands.append(stop(domain + "/" + layout.rollbackLabel)) }
        if layout.systemPlist != nil { commands.append(stop("system/" + MacInstallLayout.systemLabel)) }
        if let domain = layout.sessionDomain { commands.append(stop(domain + "/" + layout.sessionLabel)) }
        return commands
    }

    private func stop(_ serviceTarget: String) -> InstallPlan.Command {
        InstallPlan.Command([stopTool, "stop-service", serviceTarget])
    }

    private func bootstrap(_ domain: String, _ plist: String) -> InstallPlan.Command {
        InstallPlan.Command(["launchctl", "bootstrap", domain, plist])
    }
}

extension InstallPlan {
    /// The install of `layout`'s scope, its jobs stopped through `stopTool`.
    public static func install(_ layout: MacInstallLayout, stopTool: String) -> InstallPlan {
        .install(
            root: layout.installRoot, payloadName: MacInstallLayout.appName,
            definitions: LaunchdJobs(layout, stopTool: stopTool))
    }

    /// The uninstall of `layout`'s scope.
    public static func uninstall(_ layout: MacInstallLayout, stopTool: String) -> InstallPlan {
        .uninstall(root: layout.installRoot, definitions: LaunchdJobs(layout, stopTool: stopTool))
    }

    /// What a user-scope agent rewrites as it confirms an update to itself, so its property lists are always
    /// the ones its own binary writes; launchd reads them at the next login. The system scope's are root's,
    /// written only by `install --system`.
    public static func refreshJobs(_ layout: MacInstallLayout) -> InstallPlan {
        precondition(layout.scope == .user, "only the user scope rewrites its own jobs")
        return .refresh(root: layout.installRoot, definitions: LaunchdJobs(layout, stopTool: ""))
    }
}

/// The text of every property list `install` writes: the binary writes its own jobs, so they can never drift
/// from it. Every job runs the agent through `current` — the rollback check through `rollback` — so an update
/// that switches slots rewrites none of them.
///
/// A peer is kept alive only while it exits unsuccessfully (`KeepAlive` `SuccessfulExit` false), so a peer
/// relaunches into an update or a reverted slot by exiting 75, and stays stopped after exiting 0. The rollback
/// check runs every `UpdateRollbackPolicy.checkIntervalSeconds` (`StartInterval`) through `/bin/sh`, which
/// execs the previous slot's agent only while `switch-pending` exists: launchd has no condition on a path, and
/// before any update there is no `rollback` slot to run. Each job names the app's bundle, so Login Items shows
/// it as Kernova Guest Agent (`AssociatedBundleIdentifiers`).
public enum LaunchdPlists {
    /// The session peer's LaunchAgent: one per GUI login session (`LimitLoadToSessionType` `Aqua`).
    public static func session(_ layout: MacInstallLayout) -> String {
        document([
            ("Label", .string(layout.sessionLabel)),
            ("AssociatedBundleIdentifiers", .strings([MacInstallLayout.bundleIdentifier])),
            ("ProgramArguments", .strings([layout.executable(through: layout.installRoot.current), "session"])),
            ("RunAtLoad", .bool(true)),
            ("KeepAlive", .dictionary([("SuccessfulExit", .bool(false))])),
            ("LimitLoadToSessionType", .string("Aqua")),
            ("ProcessType", .string("Interactive")),
        ])
    }

    /// The system peer's LaunchDaemon, run as root.
    public static func system(_ layout: MacInstallLayout) -> String {
        document([
            ("Label", .string(MacInstallLayout.systemLabel)),
            ("AssociatedBundleIdentifiers", .strings([MacInstallLayout.bundleIdentifier])),
            ("ProgramArguments", .strings([layout.executable(through: layout.installRoot.current), "system"])),
            ("RunAtLoad", .bool(true)),
            ("KeepAlive", .dictionary([("SuccessfulExit", .bool(false))])),
        ])
    }

    /// The rollback check: a LaunchAgent in the user's GUI session for the user scope, a LaunchDaemon for the
    /// system scope.
    public static func rollback(_ layout: MacInstallLayout) -> String {
        let scope = layout.scope == .system ? "system" : "user"
        var entries: [(String, Value)] = [
            ("Label", .string(layout.rollbackLabel)),
            ("AssociatedBundleIdentifiers", .strings([MacInstallLayout.bundleIdentifier])),
            ("ProgramArguments", .strings(["/bin/sh", "-c", rollbackScript, "sh", layout.root, scope])),
            ("StartInterval", .integer(UpdateRollbackPolicy.checkIntervalSeconds)),
        ]
        if layout.scope == .user { entries.append(("LimitLoadToSessionType", .string("Aqua"))) }
        return document(entries)
    }

    /// Runs the `rollback` slot's agent's `rollback-check` for the root `$1` and the scope `$2`, only while an
    /// update's switch is pending.
    static let rollbackScript =
        #"[ -e "$1/"# + InstallRoot.switchPendingName + #"" ] || exit 0; exec "$1/"# + InstallRoot.rollbackLinkName
        + "/" + MacInstallLayout.appName + "/" + MacInstallLayout.executable + #"" rollback-check --scope "$2""#

    /// A property list value.
    indirect enum Value {
        case string(String)
        case strings([String])
        case bool(Bool)
        case integer(Int)
        case dictionary([(String, Value)])
    }

    /// The XML property list of a dictionary holding `entries` in order.
    static func document(_ entries: [(String, Value)]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(render(.dictionary(entries), indent: ""))
        </plist>

        """
    }

    private static func render(_ value: Value, indent: String) -> String {
        switch value {
        case .string(let text): return indent + "<string>" + escaped(text) + "</string>"
        case .bool(let flag): return indent + (flag ? "<true/>" : "<false/>")
        case .integer(let number): return indent + "<integer>\(number)</integer>"
        case .strings(let texts):
            return
                ([indent + "<array>"] + texts.map { render(.string($0), indent: indent + "\t") }
                + [indent + "</array>"]).joined(separator: "\n")
        case .dictionary(let entries):
            var lines = [indent + "<dict>"]
            for (key, value) in entries {
                lines.append(indent + "\t<key>" + escaped(key) + "</key>")
                lines.append(render(value, indent: indent + "\t"))
            }
            lines.append(indent + "</dict>")
            return lines.joined(separator: "\n")
        }
    }

    /// `text` with XML's markup characters escaped.
    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }
}
#endif
