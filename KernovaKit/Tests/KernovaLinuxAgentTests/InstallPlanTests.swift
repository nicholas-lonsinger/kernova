import Testing

@testable import KernovaLinuxAgent

@Suite("The installer's plan")
struct InstallPlanTests {
    static let user = UnitFilesTests.user
    static let system = UnitFilesTests.system

    @Test("A user install starts the service and the timer once its files are written")
    func userCommands() {
        #expect(
            InstallPlan.install(Self.user).after.map(\.arguments) == [
                ["systemctl", "--user", "daemon-reload"],
                ["systemctl", "--user", "enable", "--now", "kernova-agent-rollback.timer"],
                ["systemctl", "--user", "restart", "kernova-agent.service"],
            ])
        #expect(InstallPlan.install(Self.user).before.isEmpty)
    }

    @Test("A system install makes the account before systemd starts anything that runs as it")
    func systemCommands() {
        #expect(
            InstallPlan.install(Self.system).after.map(\.arguments) == [
                ["systemd-sysusers", "/etc/sysusers.d/kernova-agent.conf"],
                ["systemctl", "daemon-reload"],
                ["systemctl", "enable", "--now", "kernova-agent-rollback.timer"],
                ["systemctl", "enable", "kernova-agent-system.service"],
                ["systemctl", "restart", "kernova-agent-system.service"],
            ])
    }

    @Test("An install clears a switch an update left pending, so the rollback check never judges it")
    func clearsPendingSwitch() {
        #expect(InstallPlan.install(Self.user).removals == ["/home/pbear/.local/share/kernova-agent/switch-pending"])
    }

    @Test(
        "An uninstall stops only what is installed, then removes every file the install wrote",
        arguments: [user, system])
    func uninstallUndoesInstall(layout: InstallLayout) {
        let install = InstallPlan.install(layout)
        let uninstall = InstallPlan.uninstall(layout)
        for write in install.writes {
            let path: String
            switch write {
            case .file(let file, _, _): path = file
            case .payload(let binary, _): path = binary
            case .link(let link, _): path = link
            case .directory: continue
            }
            #expect(
                uninstall.removals.contains { path == $0 || path.hasPrefix($0 + "/") }, "\(path) is left behind")
        }
        #expect(uninstall.before.allSatisfy { $0.onlyIfPresent != nil })
        #expect(uninstall.removals.last == layout.root)
    }
}
