#if os(macOS)
import KernovaAgentCore
import KernovaTestSupport
import Testing

@testable import KernovaPlatformDarwin

@Suite("The macOS agent's command line", .caseScoped)
struct MacAgentCommandTests {
    @Test("No arguments, or only Launch Services' process serial number, run the session peer")
    func session() {
        #expect(MacAgentCommand.parse([]) == .session)
        #expect(MacAgentCommand.parse(["-psn_0_12345"]) == .session)
        #expect(MacAgentCommand.parse(["session"]) == .session)
        #expect(MacAgentCommand.parse(["system"]) == .system)
    }

    @Test("Install and uninstall take each option once")
    func install() {
        #expect(MacAgentCommand.parse(["install"]) == .install(.init()))
        #expect(
            MacAgentCommand.parse(["install", "--system", "--dry-run"])
                == .install(.init(scope: .system, dryRun: true)))
        #expect(MacAgentCommand.parse(["install", "--payload", "/Volumes/K/agent.payload"]) == nil)
        #expect(MacAgentCommand.parse(["install", "--system", "--system"]) == nil)
        #expect(MacAgentCommand.parse(["uninstall", "--system"]) == .uninstall(.init(scope: .system)))
    }

    @Test("The tools: rollback check, stop-service and the packer")
    func tools() {
        #expect(MacAgentCommand.parse(["rollback-check", "--scope", "system"]) == .rollbackCheck(.system))
        #expect(MacAgentCommand.parse(["rollback-check"]) == nil)
        #expect(
            MacAgentCommand.parse(["stop-service", "gui/501/app.kernova.macosagent"])
                == .stopService("gui/501/app.kernova.macosagent"))
        #expect(
            MacAgentCommand.parse(["pack-payload", "/a/Kernova Guest Agent.app", "/b/agent.payload"])
                == .packPayload(app: "/a/Kernova Guest Agent.app", output: "/b/agent.payload"))
        #expect(MacAgentCommand.parse(["pack-payload", "a", "/b"]) == nil)
        #expect(MacAgentCommand.parse(["--help"]) == nil)
    }
}
#endif
