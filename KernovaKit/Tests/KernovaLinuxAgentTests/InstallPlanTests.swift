import KernovaAgentInstall
import Testing

@testable import KernovaLinuxAgent

@Suite("The installer's plan")
struct InstallPlanTests {
    static let user = UnitFilesTests.user
    static let system = UnitFilesTests.system

    @Test("A user install stops the rollback check first, and starts it and the service once its files are written")
    func userCommands() {
        let plan = InstallPlan.install(Self.user)
        #expect(
            plan.before == [
                InstallPlan.Command(
                    ["systemctl", "--user", "stop", "kernova-agent-rollback.timer", "kernova-agent-rollback.service"],
                    onlyIfPresent: "/home/pbear/.config/systemd/user/kernova-agent-rollback.timer")
            ])
        #expect(
            plan.after.map(\.arguments) == [
                ["systemctl", "--user", "daemon-reload"],
                ["systemctl", "--user", "enable", "--now", "kernova-agent-rollback.timer"],
                ["systemctl", "--user", "restart", "kernova-agent.service"],
            ])
    }

    @Test("Everything under the agent's root is a tree step, and nothing else is", arguments: [user, system])
    func treeSteps(layout: InstallLayout) {
        let plan = InstallPlan.install(layout)
        for write in plan.treeWrites {
            #expect(Self.path(of: write).hasPrefix(layout.root + "/"), "\(write)")
        }
        for write in plan.writes {
            #expect(!Self.path(of: write).hasPrefix(layout.root + "/"), "\(write)")
        }
    }

    private static func path(of write: InstallPlan.Write) -> String {
        switch write {
        case .directory(let path, _), .file(let path, _, _): path
        case .freshSlot(let root, _): root.slots + "/"
        }
    }

    @Test("A system install's dry run lists every step, in the order the installer takes them")
    func systemInstallDryRun() {
        #expect(
            InstallPlan.dryRun(.install(Self.system), heading: "kernova-agent install --system will:") == [
                "kernova-agent install --system will:",
                "  run systemctl stop kernova-agent-rollback.timer kernova-agent-rollback.service, if /etc/systemd/system/kernova-agent-rollback.timer exists",
                #"  run systemd-sysusers --inline 'u kernova-agent - "Kernova guest agent" /opt/kernova-agent -'"#,
                "  remove /opt/kernova-agent/switch-pending, if present",
                "  remove /opt/kernova-agent/switch-rejected, if present",
                "  make directory /opt/kernova-agent, if missing",
                "  make directory /opt/kernova-agent/slots, if missing",
                "  write the agent as kernova-agent in the slot under /opt/kernova-agent/slots that "
                    + "/opt/kernova-agent/current does not name, record it in /opt/kernova-agent/state.json, point "
                    + "/opt/kernova-agent/rollback at it, and switch /opt/kernova-agent/current to it",
                "  make directory /etc/systemd/system, if missing",
                "  write /etc/systemd/system/kernova-agent-system.service",
                "  write /etc/systemd/system/kernova-agent-rollback.timer",
                "  write /etc/systemd/system/kernova-agent-rollback.service",
                "  make directory /etc/sysusers.d, if missing",
                "  write /etc/sysusers.d/kernova-agent.conf",
                "  run systemctl daemon-reload",
                "  run systemctl enable --now kernova-agent-rollback.timer",
                "  run systemctl enable kernova-agent-system.service",
                "  run systemctl restart kernova-agent-system.service",
            ])
    }
}
