import Testing

@testable import KernovaLinuxAgent

@Suite("kernova-agent's command line")
struct AgentCommandTests {
    @Test(
        "Each subcommand parses alone",
        arguments: [
            (["session"], AgentCommand.session), (["system"], .system), (["self-test"], .selfTest),
            (["--version"], .version),
        ])
    func subcommand(arguments: [String], command: AgentCommand) {
        #expect(AgentCommand.parse(arguments) == command)
    }

    @Test(
        "Nothing, an unknown word, or a subcommand with extra arguments is a usage error",
        arguments: [[], ["help"], ["session", "extra"], ["--system"], ["Session"], ["system", "--version"]])
    func refused(arguments: [String]) {
        #expect(AgentCommand.parse(arguments) == nil)
    }
}
