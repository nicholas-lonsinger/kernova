/// The text of every file `kernova-agent install` writes besides the binary and its metadata: the binary
/// writes its own units, so they can never drift from it.
///
/// Every unit runs the agent through `current`, so an update that switches slots rewrites none of them.
/// systemd restarts a peer that fails, and one that relaunches by exiting 75 (`RestartForceExitStatus=`),
/// never one that exits 0, which stays stopped until the next login or boot; `StartLimitIntervalSec=0`
/// keeps restarts from ever running out. `Type=exec` makes a start fail when the binary cannot be executed,
/// so the installer's `restart` reports it rather than the restart loop hiding it. The rollback check is
/// `Type=oneshot`, whose start already waits for it to exit. The rollback timer fires every 30 s, `AccuracySec=1s` because
/// systemd's default of one minute coarsens it; its service runs only while `switch-pending` exists.
///
/// The system units run the agent from `/opt/kernova-agent`. Fedora's targeted policy labels that tree
/// `usr_t` by default, which systemd executes a `User=` service from, where it refuses `var_lib_t`
/// (203/EXEC). `ProtectSystem=strict` leaves `/opt` read-only, so `ReadWritePaths=` gives the account back
/// its own root, where it updates its slots.
enum UnitFiles {
    /// The service that runs the peer of `layout`'s scope.
    static func service(_ layout: InstallLayout) -> String {
        let binary = escapedArgument(layout.current + "/" + InstallLayout.binaryName)
        let writable = escapedArgument(layout.root)
        switch layout.scope {
        case .system:
            return """
                # Written by kernova-agent install --system.
                [Unit]
                Description=Kernova guest agent (system)
                After=dbus.service systemd-logind.service
                StartLimitIntervalSec=0

                [Service]
                Type=exec
                User=\(InstallLayout.systemAccount)
                ExecStart=\(binary) system
                ReadWritePaths=\(writable)
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
                Type=exec
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
        let writable = escapedArgument(layout.root)
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
                ReadWritePaths=\(writable)
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
    /// agent's root, with no login shell.
    static func sysusers(_ layout: InstallLayout) -> String {
        """
        # Written by kernova-agent install --system.
        \(sysusersLine(layout))

        """
    }

    /// The one sysusers.d(5) line ``sysusers(_:)`` holds.
    static func sysusersLine(_ layout: InstallLayout) -> String {
        #"u \#(InstallLayout.systemAccount) - "Kernova guest agent" \#(layout.root) -"#
    }

    /// The polkit rules. The first grants the system peer's account the four power actions and nothing else:
    /// no `*-ignore-inhibit`, so a block inhibitor still stops it.
    ///
    /// The second refuses udisks' `Drive.PowerOff` on the VM's USB disks, which crashes Virtualization's
    /// VirtualMachine process. ``udevRule`` hides the action; this refuses a caller that asks anyway, as
    /// `udisksctl power-off` does, since udisksd does not check `CanPowerOff` before acting. udisks documents
    /// `drive.vendor` and `drive.model` as polkit variables holding `Drive:Vendor` and `Drive:Model`. polkit
    /// authorizes root without consulting rules.
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

        polkit.addRule(function(action, subject) {
            if ((action.id == "org.freedesktop.udisks2.power-off-drive" ||
                 action.id == "org.freedesktop.udisks2.power-off-drive-system" ||
                 action.id == "org.freedesktop.udisks2.power-off-drive-other-seat") &&
                action.lookup("drive.vendor") == "Apple" &&
                action.lookup("drive.model") == "Virtual Disk") {
                return polkit.Result.NO;
            }
        });

        """

    /// The udev rule that sets udisks' documented `UDISKS_CAN_POWER_OFF` override to 0 on the VM's USB disks,
    /// so `Drive:CanPowerOff` is false and GNOME Files offers no Safely Remove Drive. Plain eject, udisks'
    /// `Drive.Eject`, stays offered and is unaffected.
    static let udevRule = """
        # Written by kernova-agent install --system.
        ACTION!="remove", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_VENDOR}=="Apple", ENV{ID_MODEL}=="Virtual_Disk", ENV{UDISKS_CAN_POWER_OFF}="0"

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
