import Testing

@testable import KernovaLinuxAgent

/// The text of every unit, autostart entry and sysusers line, golden: a change to any of them
/// changes what every installed guest runs, so it shows here first.
@Suite("The installer's unit files")
struct UnitFilesTests {
    static let user = InstallLayout.user(
        root: "/home/pbear/.local/share/kernova-agent", configHome: "/home/pbear/.config")
    static let system = InstallLayout.system(root: "/opt/kernova-agent")

    @Test("The user rollback check runs the previous slot's binary only while a switch is pending")
    func userRollbackService() {
        #expect(
            UnitFiles.rollbackService(Self.user) == """
                # Written by kernova-agent install.
                [Unit]
                Description=Kernova guest agent update check
                ConditionPathExists=/home/pbear/.local/share/kernova-agent/switch-pending

                [Service]
                Type=oneshot
                ExecStart=/home/pbear/.local/share/kernova-agent/rollback/kernova-agent rollback-check --scope user
                SyslogIdentifier=kernova-agent

                """)
    }

    @Test("The system rollback check runs as the system peer's account")
    func systemRollbackService() {
        #expect(
            UnitFiles.rollbackService(Self.system) == """
                # Written by kernova-agent install --system.
                [Unit]
                Description=Kernova guest agent update check
                ConditionPathExists=/opt/kernova-agent/switch-pending

                [Service]
                Type=oneshot
                User=kernova-agent
                ExecStart=/opt/kernova-agent/rollback/kernova-agent rollback-check --scope system
                ReadWritePaths=/opt/kernova-agent
                NoNewPrivileges=yes
                ProtectSystem=strict
                ProtectHome=yes
                PrivateTmp=yes
                SyslogIdentifier=kernova-agent

                """)
    }

    @Test("A home with a space, a quote or a percent sign stays one ExecStart word")
    func escaping() {
        let layout = InstallLayout.user(root: "/home/Ann O'Neil/100% \"x\"/kernova-agent", configHome: "/c")
        #expect(
            UnitFiles.service(layout).contains(
                #"ExecStart="/home/Ann O'Neil/100%% \"x\"/kernova-agent/current/kernova-agent" session"#))
        #expect(
            UnitFiles.rollbackService(layout).contains(
                #"ConditionPathExists=/home/Ann O'Neil/100%% "x"/kernova-agent/switch-pending"#))
    }
}
