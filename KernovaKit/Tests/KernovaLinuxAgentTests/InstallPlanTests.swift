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

    @Test(
        "A system install makes the account before it writes anything, so what it makes in the agent's root is handed to it"
    )
    func systemCommands() {
        let plan = InstallPlan.install(Self.system)
        #expect(
            plan.before.map(\.arguments) == [
                ["systemctl", "stop", "kernova-agent-rollback.timer", "kernova-agent-rollback.service"],
                [
                    "systemd-sysusers", "--inline",
                    #"u kernova-agent - "Kernova guest agent" /opt/kernova-agent -"#,
                ],
            ])
        #expect(
            plan.after.map(\.arguments) == [
                ["systemctl", "daemon-reload"],
                ["systemctl", "enable", "--now", "kernova-agent-rollback.timer"],
                ["systemctl", "enable", "kernova-agent-system.service"],
                ["systemctl", "restart", "kernova-agent-system.service"],
            ])
        #expect(UnitFiles.sysusers(Self.system).contains(UnitFiles.sysusersLine(Self.system)))
    }

    @Test(
        "An install clears a switch an update left pending, or reverted, before it writes anything",
        arguments: [user, system])
    func clearsPendingSwitch(layout: InstallLayout) {
        let plan = InstallPlan.install(layout)
        #expect(plan.treeRemovals == [layout.switchPending, layout.switchRejected])
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

    @Test(
        "An uninstall stops only what is installed, then removes every file the install wrote",
        arguments: [user, system])
    func uninstallUndoesInstall(layout: InstallLayout) {
        let install = InstallPlan.install(layout)
        let uninstall = InstallPlan.uninstall(layout)
        #expect(uninstall.removesRoot)
        for write in install.writes {
            if case .directory = write { continue }
            #expect(uninstall.removals.contains(Self.path(of: write)), "\(write) is left behind")
        }
        #expect(uninstall.before.allSatisfy { $0.onlyIfPresent != nil })
    }

    private static func path(of write: InstallPlan.Write) -> String {
        switch write {
        case .directory(let path, _), .file(let path, _, _), .link(let path, _): path
        case .payload(let binary, _): binary
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
                "  make directory /opt/kernova-agent/slots/a, if missing",
                "  write /opt/kernova-agent/slots/a/kernova-agent, the agent, and /opt/kernova-agent/state.json",
                "  link /opt/kernova-agent/current -> slots/a",
                "  make directory /etc/systemd/system, if missing",
                "  write /etc/systemd/system/kernova-agent-system.service",
                "  write /etc/systemd/system/kernova-agent-rollback.timer",
                "  write /etc/systemd/system/kernova-agent-rollback.service",
                "  make directory /etc/sysusers.d, if missing",
                "  write /etc/sysusers.d/kernova-agent.conf",
                "  make directory /etc/polkit-1/rules.d, if missing",
                "  write /etc/polkit-1/rules.d/50-kernova-agent.rules",
                "  run systemctl daemon-reload",
                "  run systemctl enable --now kernova-agent-rollback.timer",
                "  run systemctl enable kernova-agent-system.service",
                "  run systemctl restart kernova-agent-system.service",
            ])
    }

    @Test("A system uninstall's dry run lists every step, in the order the installer takes them")
    func systemUninstallDryRun() {
        #expect(
            InstallPlan.dryRun(.uninstall(Self.system), heading: "h") == [
                "h",
                "  run systemctl disable --now kernova-agent-rollback.timer, if /etc/systemd/system/kernova-agent-rollback.timer exists",
                "  run systemctl disable --now kernova-agent-system.service, if /etc/systemd/system/kernova-agent-system.service exists",
                "  remove /etc/systemd/system/kernova-agent-system.service, if present",
                "  remove /etc/systemd/system/kernova-agent-rollback.timer, if present",
                "  remove /etc/systemd/system/kernova-agent-rollback.service, if present",
                "  remove /etc/polkit-1/rules.d/50-kernova-agent.rules, if present",
                "  remove /etc/sysusers.d/kernova-agent.conf, if present",
                "  remove /opt/kernova-agent and everything in it, if present",
                "  run systemctl daemon-reload",
            ])
    }
}
