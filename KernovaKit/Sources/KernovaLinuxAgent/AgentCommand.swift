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

    /// The usage line printed for arguments `parse(_:)` refuses.
    static let usage = "usage: kernova-agent session | system | self-test | --version"

    /// The command `arguments` — those after the program name — ask for, or nil when they ask for none.
    static func parse(_ arguments: [String]) -> AgentCommand? {
        switch arguments {
        case ["session"]: .session
        case ["system"]: .system
        case ["self-test"]: .selfTest
        case ["--version"]: .version
        default: nil
        }
    }
}
