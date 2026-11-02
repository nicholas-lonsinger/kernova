import KernovaAgentCore
import Testing

@testable import KernovaLinuxAgent

@Suite("kernova-agent's command line")
struct AgentCommandTests {
    typealias Request = AgentCommand.InstallRequest

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

    @Test(
        "install and uninstall take --system, --no-systemctl and --root, in any order",
        arguments: [
            (["install"], AgentCommand.install(Request())),
            (["install", "--system"], .install(Request(scope: .system))),
            (["uninstall", "--system"], .uninstall(Request(scope: .system))),
            (["install", "--no-systemctl"], .install(Request(runsSystemd: false))),
            (["install", "--dry-run", "--system"], .install(Request(scope: .system, dryRun: true))),
            (["uninstall", "--dry-run"], .uninstall(Request(dryRun: true))),
            (
                ["install", "--root", "/tmp/stage", "--system", "--no-systemctl"],
                .install(Request(scope: .system, root: "/tmp/stage", runsSystemd: false))
            ),
            (
                ["uninstall", "--no-systemctl", "--root", "/stage"],
                .uninstall(Request(root: "/stage", runsSystemd: false))
            ),
        ])
    func install(arguments: [String], command: AgentCommand) {
        #expect(AgentCommand.parse(arguments) == command)
    }

    @Test(
        "Nothing, an unknown word, or a subcommand with extra arguments is a usage error",
        arguments: [
            [], ["help"], ["session", "extra"], ["--system"], ["Session"], ["system", "--version"],
            ["install", "--user"], ["install", "--system", "--system"], ["install", "--root"],
            ["install", "--dry-run", "--dry-run"],
            ["install", "--root", "relative", "--no-systemctl"],
            // A staging root has no systemd to run.
            ["install", "--root", "/stage"], ["uninstall", "session"],
            ["rollback-check"], ["rollback-check", "--scope"], ["rollback-check", "--scope", "unspecified"],
            ["rollback-check", "--system"],
        ])
    func refused(arguments: [String]) {
        #expect(AgentCommand.parse(arguments) == nil)
    }
}
