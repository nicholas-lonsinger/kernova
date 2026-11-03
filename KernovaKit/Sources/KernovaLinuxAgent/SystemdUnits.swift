import KernovaAgentCore
import KernovaAgentInstall

/// What one scope's install puts in systemd's hands: the units, the autostart entry or the account's
/// declaration (``UnitFiles``), and the `systemctl` and `systemd-sysusers` commands around them.
struct SystemdUnits: ServiceDefinitions {
    let layout: InstallLayout

    init(_ layout: InstallLayout) {
        self.layout = layout
    }

    var writes: [InstallPlan.Write] {
        var writes: [InstallPlan.Write] = [
            .directory(path: layout.unitDirectory, mode: 0o755),
            .file(path: unit(layout.serviceName), mode: 0o644, text: UnitFiles.service(layout)),
            .file(path: unit(InstallLayout.rollbackTimerName), mode: 0o644, text: UnitFiles.rollbackTimer(layout)),
            .file(
                path: unit(InstallLayout.rollbackServiceName), mode: 0o644, text: UnitFiles.rollbackService(layout)),
        ]
        if layout.scope == .system {
            writes += [
                .directory(path: "/etc/sysusers.d", mode: 0o755),
                .file(path: InstallLayout.sysusersFile, mode: 0o644, text: UnitFiles.sysusers(layout)),
            ]
        } else if let autostart = layout.autostartDirectory {
            writes += [
                .directory(path: autostart, mode: 0o755),
                .file(path: autostart + "/" + InstallLayout.autostartName, mode: 0o644, text: UnitFiles.autostartEntry),
            ]
        }
        return writes
    }

    var beforeInstall: [InstallPlan.Command] {
        var commands = [
            InstallPlan.Command(
                systemctl + ["stop", InstallLayout.rollbackTimerName, InstallLayout.rollbackServiceName],
                onlyIfPresent: unit(InstallLayout.rollbackTimerName))
        ]
        if layout.scope == .system {
            // The account exists before anything is written, so the tree is handed to it as it is made.
            commands.append(InstallPlan.Command(["systemd-sysusers", "--inline", UnitFiles.sysusersLine(layout)]))
        }
        return commands
    }

    var afterInstall: [InstallPlan.Command] {
        // Started now, so the agent connects without a fresh login (or boot); restarted, so a reinstall runs the
        // binary it just wrote.
        var commands = [
            InstallPlan.Command(systemctl + ["daemon-reload"]),
            InstallPlan.Command(systemctl + ["enable", "--now", InstallLayout.rollbackTimerName]),
        ]
        if layout.scope == .system { commands.append(InstallPlan.Command(systemctl + ["enable", layout.serviceName])) }
        commands.append(InstallPlan.Command(systemctl + ["restart", layout.serviceName]))
        return commands
    }

    /// The system account stays, as systemd-sysusers leaves every account it made, so its uid is never reused for
    /// files it may still own.
    var beforeUninstall: [InstallPlan.Command] {
        [
            InstallPlan.Command(
                systemctl + ["disable", "--now", InstallLayout.rollbackTimerName],
                onlyIfPresent: unit(InstallLayout.rollbackTimerName)),
            InstallPlan.Command(
                systemctl + (layout.scope == .system ? ["disable", "--now"] : ["stop"]) + [layout.serviceName],
                onlyIfPresent: unit(layout.serviceName)),
        ]
    }

    var afterUninstall: [InstallPlan.Command] { [InstallPlan.Command(systemctl + ["daemon-reload"])] }

    var afterRefresh: [InstallPlan.Command] { [InstallPlan.Command(systemctl + ["daemon-reload"])] }

    private var systemctl: [String] { layout.scope == .system ? ["systemctl"] : ["systemctl", "--user"] }

    private func unit(_ name: String) -> String {
        layout.unitDirectory + "/" + name
    }
}

extension InstallPlan {
    /// The install of `layout`'s scope.
    static func install(_ layout: InstallLayout) -> InstallPlan {
        .install(root: layout.installRoot, payloadName: InstallLayout.binaryName, definitions: SystemdUnits(layout))
    }

    /// The uninstall of `layout`'s scope.
    static func uninstall(_ layout: InstallLayout) -> InstallPlan {
        .uninstall(root: layout.installRoot, definitions: SystemdUnits(layout))
    }

    /// What a user-scope agent rewrites as it confirms an update to itself, so its units and autostart entry are
    /// always the ones its own binary writes. The system scope's units are root's, written only by
    /// `install --system`, and never rewritten by the unprivileged system peer.
    static func refreshUnits(_ layout: InstallLayout) -> InstallPlan {
        precondition(layout.scope == .user, "only the user scope rewrites its own units")
        return .refresh(root: layout.installRoot, definitions: SystemdUnits(layout))
    }
}
