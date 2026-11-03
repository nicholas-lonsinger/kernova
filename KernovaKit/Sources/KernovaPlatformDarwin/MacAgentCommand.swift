#if os(macOS)
import KernovaAgentCore

/// What the macOS agent's executable was asked to do. With no arguments it is the session peer, as launching
/// the app any other way runs it.
public enum MacAgentCommand: Equatable, Sendable {
    /// Run the session peer, the app in the user's GUI session.
    case session
    /// Run the system peer, a daemon with no window-server connection.
    case system
    /// Print the agent's identity and exit 0.
    case selfTest
    /// Print the version label and exit 0.
    case version
    /// Install the payload in a scope.
    case install(InstallRequest)
    /// Remove the install of a scope.
    case uninstall(InstallRequest)
    /// Run the rollback check once for the install of a scope, as its rollback job does.
    case rollbackCheck(InstallScope)
    /// Stop a launchd job and wait until launchd has let it go, as an install does before it loads it again.
    case stopService(String)
    /// Pack an app bundle as an update payload, as the build does.
    case packPayload(app: String, output: String)

    /// How an install or uninstall was asked for.
    public struct InstallRequest: Equatable, Sendable {
        /// `.user` by default, `.system` with `--system`.
        public var scope: InstallScope = .user
        /// `--dry-run`: print what it would do, and change nothing.
        public var dryRun = false
        /// `--payload <file>`: the payload to install; nil for the one beside the app bundle.
        public var payload: String?

        /// A request for `scope`, a dry run when `dryRun`, installing `payload`.
        public init(scope: InstallScope = .user, dryRun: Bool = false, payload: String? = nil) {
            self.scope = scope
            self.dryRun = dryRun
            self.payload = payload
        }
    }

    /// The usage line printed for arguments `parse(_:)` refuses.
    public static let usage = """
        usage: KernovaMacOSAgent [session | system | self-test | --version]
               KernovaMacOSAgent install [--system] [--dry-run] [--payload <file>]
               KernovaMacOSAgent uninstall [--system] [--dry-run]
               KernovaMacOSAgent rollback-check --scope user | system
               KernovaMacOSAgent stop-service <service-target>
               KernovaMacOSAgent pack-payload <app> <output>
        """

    /// The command `arguments` — those after the program name — ask for, or nil when they ask for none. A
    /// `-psn_…` argument, which Launch Services passes an app it opens, is ignored.
    public static func parse(_ arguments: [String]) -> MacAgentCommand? {
        let arguments = arguments.filter { !$0.hasPrefix("-psn_") }
        switch arguments.first {
        case "install": return parseInstall(arguments.dropFirst(), payloadAllowed: true).map(Self.install)
        case "uninstall": return parseInstall(arguments.dropFirst(), payloadAllowed: false).map(Self.uninstall)
        default: break
        }
        switch arguments {
        case [], ["session"]: return .session
        case ["system"]: return .system
        case ["self-test"]: return .selfTest
        case ["--version"]: return .version
        case ["rollback-check", "--scope", "user"]: return .rollbackCheck(.user)
        case ["rollback-check", "--scope", "system"]: return .rollbackCheck(.system)
        default: break
        }
        if arguments.count == 2, arguments[0] == "stop-service", !arguments[1].isEmpty {
            return .stopService(arguments[1])
        }
        if arguments.count == 3, arguments[0] == "pack-payload", arguments[1].hasPrefix("/"),
            arguments[2].hasPrefix("/")
        {
            return .packPayload(app: arguments[1], output: arguments[2])
        }
        return nil
    }

    /// The options of `install` or `uninstall`, each at most once.
    private static func parseInstall(_ arguments: ArraySlice<String>, payloadAllowed: Bool) -> InstallRequest? {
        var request = InstallRequest()
        var seen = Set<String>()
        var remaining = arguments
        while let option = remaining.popFirst() {
            guard seen.insert(option).inserted else { return nil }
            switch option {
            case "--system": request.scope = .system
            case "--dry-run": request.dryRun = true
            case "--payload" where payloadAllowed:
                guard let payload = remaining.popFirst(), payload.hasPrefix("/") else { return nil }
                request.payload = payload
            default: return nil
            }
        }
        return request
    }
}
#endif
