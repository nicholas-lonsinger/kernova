import KernovaAgentCore
import Testing

@testable import KernovaLinuxAgent

@Suite("kernova-agent's command line")
struct AgentCommandTests {

    @Test(
        "Each subcommand parses alone",
        arguments: [
            (["session"], AgentCommand.session), (["system"], .system), (["self-test"], .selfTest),
            (["--version"], .version), (["rollback-check", "--scope", "user"], .rollbackCheck(.user)),
            (["rollback-check", "--scope", "system"], .rollbackCheck(.system)),
        ])
    func subcommand(arguments: [String], command: AgentCommand) {
        #expect(AgentCommand.parse(arguments) == command)
    }
}
