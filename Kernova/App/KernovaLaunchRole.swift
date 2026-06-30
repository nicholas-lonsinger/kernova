import Foundation

/// Which role the Kernova executable plays for a given launch.
///
/// One binary, three roles. The launchd-managed background agent is the resident
/// process that owns the VMs and vends `…xpc`; a launcher is the
/// short-lived foreground process Finder spawns on a double-click; and the
/// foreground-for-testing role keeps the unit-test host a plain app.
/// `AppDelegate.main()` resolves the role once and installs the matching
/// `NSApplicationDelegate`.
enum KernovaLaunchRole: Equatable {
    /// Unit-test host (`BUNDLE_LOADER`): a plain foreground app, so the existing
    /// suite that launches `Kernova.app` is unaffected. The test host is not
    /// launchd-managed and cannot host the `…xpc` Mach service, so none of
    /// the agent machinery runs.
    case foregroundForTesting
    /// The resident agent: launchd ran the executable with `--background`. Hosts
    /// `…xpc`, rests headless in `.accessory`, keeps VMs running when the
    /// window closes, and summons its GUI on demand.
    case backgroundAgent
    /// A foreground process Finder spawned on a double-click (or a Login-Items
    /// entry). Registers the agent if needed, asks the resident agent to show its
    /// GUI, and exits.
    case launcher

    /// The argv flag that marks the resident-agent role.
    ///
    /// Passed only by the bundled LaunchAgent plist — a Finder double-click never
    /// passes it, so it lands in `.launcher`.
    static let backgroundFlag = "--background"

    /// Resolves the role from the process arguments and environment.
    ///
    /// Test detection wins over the flag so a hypothetical `--background` under
    /// XCTest still takes the (non-launchd) foreground path rather than trying to
    /// host a Mach service the test host can't register.
    static func resolve(arguments: [String], environment: [String: String]) -> KernovaLaunchRole {
        if environment["XCTestConfigurationFilePath"] != nil { return .foregroundForTesting }
        if arguments.contains(backgroundFlag) { return .backgroundAgent }
        return .launcher
    }
}
