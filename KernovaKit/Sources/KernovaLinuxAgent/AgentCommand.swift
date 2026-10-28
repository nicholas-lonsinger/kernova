import KernovaAgentCore

/// What `kernova-agent` was asked to do.
enum AgentCommand: Equatable {
    /// Run the session peer, for the user the process runs as.
    case session
    /// Run the system peer.
    case system
    /// Print the agent's identity and exit 0.
    case selfTest
    /// Print the version and exit 0.
    case version
    /// Install this binary in a scope.
    case install(InstallRequest)
    /// Remove the install of a scope.
    case uninstall(InstallRequest)

    /// How an install or uninstall was asked for.
    struct InstallRequest: Equatable {
        /// `.user` by default, `.system` with `--system`.
        var scope: InstallScope = .user
        /// `--root <dir>`: every path written or removed is under `dir`, as a package build's staging root
        /// is, while what the files say names the paths without it.
        var root: String?
        /// False with `--no-systemctl`: no systemd tool runs.
        var runsSystemd = true
    }

    /// The usage line printed for arguments `parse(_:)` refuses.
    static let usage = """
        usage: kernova-agent session | system | self-test | --version
               kernova-agent install | uninstall [--system] [--no-systemctl [--root <dir>]]
        """

    /// The command `arguments` — those after the program name — ask for, or nil when they ask for none.
    static func parse(_ arguments: [String]) -> AgentCommand? {
        switch arguments.first {
        case "install": parseInstall(arguments.dropFirst()).map(AgentCommand.install)
        case "uninstall": parseInstall(arguments.dropFirst()).map(AgentCommand.uninstall)
        default:
            switch arguments {
            case ["session"]: .session
            case ["system"]: .system
            case ["self-test"]: .selfTest
            case ["--version"]: .version
            default: nil
            }
        }
    }

    /// The options of `install` or `uninstall`, each at most once. `--root` needs `--no-systemctl`: a
    /// staging root has no systemd to run.
    private static func parseInstall(_ arguments: ArraySlice<String>) -> InstallRequest? {
        var request = InstallRequest()
        var seen = Set<String>()
        var remaining = arguments
        while let option = remaining.popFirst() {
            guard seen.insert(option).inserted else { return nil }
            switch option {
            case "--system": request.scope = .system
            case "--no-systemctl": request.runsSystemd = false
            case "--root":
                guard let root = remaining.popFirst(), root.hasPrefix("/") else { return nil }
                request.root = root
            default: return nil
            }
        }
        if request.root != nil, request.runsSystemd { return nil }
        return request
    }
}
