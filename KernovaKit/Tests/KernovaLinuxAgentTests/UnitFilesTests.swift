import KernovaAgentCore
import Testing

@testable import KernovaLinuxAgent

/// The text of every unit, autostart entry, sysusers line and polkit rule, golden: a change to any of them
/// changes what every installed guest runs, so it shows here first.
@Suite("The installer's unit files")
struct UnitFilesTests {
    static let user = InstallLayout.user(
        root: "/home/pbear/.local/share/kernova-agent", configHome: "/home/pbear/.config")
    static let system = InstallLayout.system(root: "/opt/kernova-agent")

    @Test(
        "The session service runs the peer through current, restarted on failure or exit 75 without limit; a clean exit stays stopped"
    )
    func userService() {
        #expect(
            UnitFiles.service(Self.user) == """
                # Written by kernova-agent install.
                [Unit]
                Description=Kernova guest agent (session)
                PartOf=graphical-session.target
                After=graphical-session.target
                StartLimitIntervalSec=0

                [Service]
                Type=exec
                ExecStart=/home/pbear/.local/share/kernova-agent/current/kernova-agent session
                Restart=on-failure
                RestartForceExitStatus=75
                RestartSec=5s
                SyslogIdentifier=kernova-agent

                """)
    }

    @Test(
        "The system service runs the peer as its own account, sandboxed, at boot, restarted as the session service is"
    )
    func systemService() {
        #expect(
            UnitFiles.service(Self.system) == """
                # Written by kernova-agent install --system.
                [Unit]
                Description=Kernova guest agent (system)
                After=dbus.service systemd-logind.service
                StartLimitIntervalSec=0

                [Service]
                Type=exec
                User=kernova-agent
                ExecStart=/opt/kernova-agent/current/kernova-agent system
                ReadWritePaths=/opt/kernova-agent
                Restart=on-failure
                RestartForceExitStatus=75
                RestartSec=5s
                NoNewPrivileges=yes
                ProtectSystem=strict
                ProtectHome=yes
                PrivateTmp=yes
                SyslogIdentifier=kernova-agent

                [Install]
                WantedBy=multi-user.target

                """)
    }

    @Test("The rollback timer fires every 30 s to the second (R7)", arguments: [user, system])
    func rollbackTimer(layout: InstallLayout) {
        let header =
            layout.scope == .system
            ? "# Written by kernova-agent install --system." : "# Written by kernova-agent install."
        #expect(
            UnitFiles.rollbackTimer(layout) == """
                \(header)
                [Unit]
                Description=Kernova guest agent update check

                [Timer]
                OnActiveSec=30s
                OnUnitActiveSec=30s
                AccuracySec=1s

                [Install]
                WantedBy=timers.target

                """)
    }

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

    @Test("XDG autostart starts the user service")
    func autostart() {
        #expect(
            UnitFiles.autostartEntry == """
                [Desktop Entry]
                Type=Application
                Name=Kernova guest agent
                Comment=Connects this session to Kernova
                Exec=systemctl --user start kernova-agent.service
                NoDisplay=true
                X-GNOME-Autostart-enabled=true

                """)
    }

    @Test("sysusers declares a system account homed at the agent's root, with no shell")
    func sysusers() {
        #expect(
            UnitFiles.sysusers(Self.system) == """
                # Written by kernova-agent install --system.
                u kernova-agent - "Kernova guest agent" /opt/kernova-agent -

                """)
    }

    @Test("polkit grants the account power-off and reboot, across sessions and past inhibitors, and nothing else")
    func polkit() {
        #expect(
            UnitFiles.polkitRule == """
                // Written by kernova-agent install --system.
                polkit.addRule(function(action, subject) {
                    if (subject.user == "kernova-agent" &&
                        (action.id == "org.freedesktop.login1.power-off" ||
                         action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
                         action.id == "org.freedesktop.login1.power-off-ignore-inhibit" ||
                         action.id == "org.freedesktop.login1.reboot" ||
                         action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
                         action.id == "org.freedesktop.login1.reboot-ignore-inhibit")) {
                        return polkit.Result.YES;
                    }
                });

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
