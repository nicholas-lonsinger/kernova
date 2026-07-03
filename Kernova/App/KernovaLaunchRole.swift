import Foundation

/// Which role the Kernova executable plays for a given launch.
///
/// One binary, five roles. The launchd-managed background agent is the resident
/// process that owns the VMs and vends `…xpc`; a launcher is the
/// short-lived foreground process Finder spawns on a double-click; the
/// foreground-for-testing role keeps the unit-test host a plain app; and two
/// developer-only roles let a Debug build (which never auto-registers, issue
/// #451) either run its GUI directly (`--foreground`) or intentionally register
/// *this* copy as the login agent (`--register-agent`). `AppDelegate.main()`
/// resolves the role once and installs the matching `NSApplicationDelegate` (or,
/// for `--register-agent`, registers and exits).
enum KernovaLaunchRole: Equatable {
    /// Unit-test host (`BUNDLE_LOADER`): a plain foreground app, so the existing
    /// suite that launches `Kernova.app` is unaffected. The test host is not
    /// launchd-managed and cannot host the `…xpc` Mach service, so none of
    /// the agent machinery — and none of the registration path — runs.
    case foregroundForTesting
    /// The resident agent: launchd ran the executable with `--background`. Hosts
    /// `…xpc`, rests headless in `.accessory`, keeps VMs running when the
    /// window closes, and summons its GUI on demand.
    case backgroundAgent
    /// A foreground process Finder spawned on a double-click (or a Login-Items
    /// entry). Reads the agent status and either summons the resident agent's GUI
    /// or (Release, unregistered, in `/Applications`) registers first; a Debug
    /// build never auto-registers here.
    case launcher
    /// Developer role (`--foreground`): run the GUI directly as a plain
    /// foreground app, bypassing the launcher/agent dance entirely. Never
    /// registers and never idle-quits — the escape hatch for iterating on the UI
    /// with a Debug build that no longer auto-registers (issue #451).
    case foreground
    /// Developer role (`--register-agent`): register *this* copy as the
    /// launch-at-login agent and exit, overriding the Debug and `/Applications`
    /// gates. The intentional way to make a dev build become the resident agent.
    case registerAgent

    /// The argv flag that marks the resident-agent role.
    ///
    /// Passed only by the bundled LaunchAgent plist — a Finder double-click never
    /// passes it, so it lands in `.launcher`.
    static let backgroundFlag = "--background"

    /// The argv flag for the developer foreground-GUI role (`.foreground`).
    static let foregroundFlag = "--foreground"

    /// The argv flag for the explicit register-this-copy role (`.registerAgent`).
    static let registerAgentFlag = "--register-agent"

    /// Resolves the role from the process arguments and environment.
    ///
    /// Test detection wins over every flag so a hypothetical `--background` /
    /// `--register-agent` / `--foreground` under XCTest still takes the
    /// (non-launchd, never-registering) foreground path rather than trying to host
    /// a Mach service the test host can't register — or, worse, registering the
    /// login agent from a test run.
    static func resolve(arguments: [String], environment: [String: String]) -> KernovaLaunchRole {
        if environment["XCTestConfigurationFilePath"] != nil { return .foregroundForTesting }
        if arguments.contains(backgroundFlag) { return .backgroundAgent }
        if arguments.contains(registerAgentFlag) { return .registerAgent }
        if arguments.contains(foregroundFlag) { return .foreground }
        return .launcher
    }
}
