/// The text of every file `kernova-agent install` writes besides the binary and its metadata: the binary
/// writes its own units, so they can never drift from it.
///
/// Every unit runs the agent through `current`, so an update that switches slots rewrites none of them.
/// systemd restarts a peer that fails, and one that relaunches by exiting 75 (`RestartForceExitStatus=`),
/// never one that exits 0, which stays stopped until the next login or boot; `StartLimitIntervalSec=0`
/// keeps restarts from ever running out. The rollback timer fires every 30 s, `AccuracySec=1s` because
/// systemd's default of one minute coarsens it; its service runs only while `switch-pending` exists.
enum UnitFiles {
    /// The service that runs the peer of `layout`'s scope.
    static func service(_ layout: InstallLayout) -> String {
        let binary = escapedArgument(layout.current + "/" + InstallLayout.binaryName)
        switch layout.scope {
        case .system:
            return """
                # Written by kernova-agent install --system.
                [Unit]
                Description=Kernova guest agent (system)
                After=dbus.service systemd-logind.service
                StartLimitIntervalSec=0

                [Service]
                User=\(InstallLayout.systemAccount)
                ExecStart=\(binary) system
                StateDirectory=kernova-agent
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

                """
        default:
            return """
                # Written by kernova-agent install.
                [Unit]
                Description=Kernova guest agent (session)
                PartOf=graphical-session.target
                After=graphical-session.target
                StartLimitIntervalSec=0

                [Service]
                ExecStart=\(binary) session
                Restart=on-failure
                RestartForceExitStatus=75
                RestartSec=5s
                SyslogIdentifier=kernova-agent

                """
        }
    }

    /// The timer that runs the rollback check.
    static func rollbackTimer(_ layout: InstallLayout) -> String {
        """
        # Written by kernova-agent install\(layout.scope == .system ? " --system" : "").
        [Unit]
        Description=Kernova guest agent update check

        [Timer]
        OnActiveSec=30s
        OnUnitActiveSec=30s
        AccuracySec=1s

        [Install]
        WantedBy=timers.target

        """
    }

    /// The rollback check, which runs the previous slot's binary while a switch is unconfirmed.
    static func rollbackService(_ layout: InstallLayout) -> String {
        let condition = escapedSpecifiers(layout.switchPending)
        let binary = escapedArgument(layout.rollback + "/" + InstallLayout.binaryName)
        switch layout.scope {
        case .system:
            return """
                # Written by kernova-agent install --system.
                [Unit]
                Description=Kernova guest agent update check
                ConditionPathExists=\(condition)

                [Service]
                Type=oneshot
                User=\(InstallLayout.systemAccount)
                ExecStart=\(binary) rollback-check --scope system
                StateDirectory=kernova-agent
                NoNewPrivileges=yes
                ProtectSystem=strict
                ProtectHome=yes
                PrivateTmp=yes
                SyslogIdentifier=kernova-agent

                """
        default:
            return """
                # Written by kernova-agent install.
                [Unit]
                Description=Kernova guest agent update check
                ConditionPathExists=\(condition)

                [Service]
                Type=oneshot
                ExecStart=\(binary) rollback-check --scope user
                SyslogIdentifier=kernova-agent

                """
        }
    }

    /// The XDG autostart entry that starts the user service at login.
    static let autostartEntry = """
        [Desktop Entry]
        Type=Application
        Name=Kernova guest agent
        Comment=Connects this session to Kernova
        Exec=systemctl --user start kernova-agent.service
        NoDisplay=true
        X-GNOME-Autostart-enabled=true

        """

    /// The system peer's account, for systemd-sysusers: a system user with its own group, homed at the
    /// state directory, with no login shell.
    static func sysusers(_ layout: InstallLayout) -> String {
        """
        # Written by kernova-agent install --system.
        u \(InstallLayout.systemAccount) - "Kernova guest agent" \(layout.root) -

        """
    }

    /// The polkit rule granting the system peer's account the four power actions and nothing else: no
    /// `*-ignore-inhibit`, so a block inhibitor still stops it.
    static let polkitRule = """
        // Written by kernova-agent install --system.
        polkit.addRule(function(action, subject) {
            if (subject.user == "\(InstallLayout.systemAccount)" &&
                (action.id == "org.freedesktop.login1.power-off" ||
                 action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
                 action.id == "org.freedesktop.login1.reboot" ||
                 action.id == "org.freedesktop.login1.reboot-multiple-sessions")) {
                return polkit.Result.YES;
            }
        });

        """

    /// `text` with systemd.unit(5)'s specifier character escaped.
    static func escapedSpecifiers(_ text: String) -> String {
        escaping(text) { $0 == "%" ? "%%" : nil }
    }

    /// `path` as one systemd.service(5) command-line word: specifiers escaped, and double-quoted with
    /// backslash escapes when it holds whitespace, a quote or a backslash.
    static func escapedArgument(_ path: String) -> String {
        let escaped = escapedSpecifiers(path)
        guard escaped.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "'" || $0 == "\\" }) else {
            return escaped
        }
        return "\"" + escaping(escaped) { $0 == "\\" || $0 == "\"" ? "\\\($0)" : nil } + "\""
    }

    /// `text` with each character `replacement` answers for replaced by its answer.
    private static func escaping(_ text: String, _ replacement: (Character) -> String?) -> String {
        var result = ""
        for character in text { result += replacement(character) ?? String(character) }
        return result
    }
}
