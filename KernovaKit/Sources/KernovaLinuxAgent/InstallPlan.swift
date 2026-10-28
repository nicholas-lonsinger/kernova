#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore

/// Everything `kernova-agent install` or `uninstall` does in one scope, as data: what it writes and removes,
/// and the commands it runs. ``Installer`` carries it out in this order: ``before``, ``treeRemovals``, the
/// agent's own ``root`` made, ``treeWrites``, ``writes``, ``removals``, the root emptied and removed when
/// ``removesRoot``, then ``after``.
///
/// The tree under ``root`` is the one the system scope's account owns. The installer reaches it only through
/// descriptors and hands what it makes there to the account (``Installer``); an uninstall empties it the same
/// way, then removes it. Everything else is written by, and belongs to, whoever runs the installer.
struct InstallPlan: Equatable {
    /// One thing written.
    enum Write: Equatable {
        /// A directory, made with `mode` when missing; one already there keeps its own.
        case directory(path: String, mode: UInt16)
        /// A file holding `text`, replaced whole.
        case file(path: String, mode: UInt16, text: String)
        /// The agent binary the installer runs from, copied to `binary` with mode `0o755`, then the slot
        /// metadata recording it at `state`.
        case payload(binary: String, state: String)
        /// A symbolic link to `target`, replaced whole.
        case link(path: String, target: String)
    }

    /// One command run, from `PATH`, unless the installer was asked to run none.
    struct Command: Equatable {
        var arguments: [String]
        /// The command runs only when this path exists.
        var onlyIfPresent: String?

        init(_ arguments: [String], onlyIfPresent: String? = nil) {
            self.arguments = arguments
            self.onlyIfPresent = onlyIfPresent
        }
    }

    /// The agent's own root, which ``treeRemovals`` and ``treeWrites`` stay inside.
    var root: String
    /// Commands run before anything is written or removed.
    var before: [Command] = []
    /// What is removed under ``root`` before anything is written.
    var treeRemovals: [String] = []
    /// What is written under ``root``, in order.
    var treeWrites: [Write] = []
    /// What is written outside ``root``, in order.
    var writes: [Write] = []
    /// What is removed outside ``root``, files and links singly; a missing one is skipped.
    var removals: [String] = []
    /// Whether ``root`` is emptied and removed.
    var removesRoot = false
    /// Commands run after.
    var after: [Command] = []

    /// The install of `layout`'s scope.
    ///
    /// A fresh install fills slot `a` and points `current` at it. Before it writes anything it stops the
    /// rollback check and clears any switch an update left pending, so no check judges a half-written root
    /// or the fresh install; it starts the check again at the end.
    static func install(_ layout: InstallLayout) -> InstallPlan {
        var plan = InstallPlan(root: layout.root)
        let systemctl = systemctlPrefix(layout)
        plan.before = [
            Command(
                systemctl + ["stop", InstallLayout.rollbackTimerName, InstallLayout.rollbackServiceName],
                onlyIfPresent: unit(layout, InstallLayout.rollbackTimerName))
        ]
        plan.treeRemovals = [layout.switchPending]
        plan.treeWrites = [
            .directory(path: layout.root + "/slots", mode: 0o755),
            .directory(path: layout.installSlot, mode: 0o755),
            .payload(binary: layout.installSlot + "/" + InstallLayout.binaryName, state: layout.state),
            .link(path: layout.current, target: InstallLayout.installSlotLink),
        ]
        plan.writes = [
            .directory(path: layout.unitDirectory, mode: 0o755),
            .file(path: unit(layout, layout.serviceName), mode: 0o644, text: UnitFiles.service(layout)),
            .file(
                path: unit(layout, InstallLayout.rollbackTimerName), mode: 0o644,
                text: UnitFiles.rollbackTimer(layout)),
            .file(
                path: unit(layout, InstallLayout.rollbackServiceName), mode: 0o644,
                text: UnitFiles.rollbackService(layout)),
        ]
        switch layout.scope {
        case .system:
            // The account exists before anything is written, so the tree is handed to it as it is made.
            plan.before.append(Command(["systemd-sysusers", "--inline", UnitFiles.sysusersLine(layout)]))
            plan.writes += [
                .directory(path: "/etc/sysusers.d", mode: 0o755),
                .file(path: InstallLayout.sysusersFile, mode: 0o644, text: UnitFiles.sysusers(layout)),
                .directory(path: "/etc/polkit-1/rules.d", mode: 0o755),
                .file(path: InstallLayout.polkitRuleFile, mode: 0o644, text: UnitFiles.polkitRule),
            ]
            plan.after = [
                Command(systemctl + ["daemon-reload"]),
                Command(systemctl + ["enable", "--now", InstallLayout.rollbackTimerName]),
                Command(systemctl + ["enable", layout.serviceName]),
                Command(systemctl + ["restart", layout.serviceName]),
            ]
        default:
            if let autostart = layout.autostartDirectory {
                plan.writes += [
                    .directory(path: autostart, mode: 0o755),
                    .file(
                        path: autostart + "/" + InstallLayout.autostartName, mode: 0o644,
                        text: UnitFiles.autostartEntry),
                ]
            }
            // Started now, so the agent connects without a fresh login; restarted, so a reinstall runs the
            // binary it just wrote.
            plan.after = [
                Command(systemctl + ["daemon-reload"]),
                Command(systemctl + ["enable", "--now", InstallLayout.rollbackTimerName]),
                Command(systemctl + ["restart", layout.serviceName]),
            ]
        }
        return plan
    }

    /// The uninstall of `layout`'s scope: stops what runs, then removes every file the install wrote. The
    /// system account stays, as systemd-sysusers leaves every account it made, so its uid is never reused
    /// for files it may still own.
    static func uninstall(_ layout: InstallLayout) -> InstallPlan {
        var plan = InstallPlan(root: layout.root)
        let systemctl = systemctlPrefix(layout)
        let service = unit(layout, layout.serviceName)
        let timer = unit(layout, InstallLayout.rollbackTimerName)
        plan.before = [
            Command(systemctl + ["disable", "--now", InstallLayout.rollbackTimerName], onlyIfPresent: timer)
        ]
        plan.before.append(
            layout.scope == .system
                ? Command(systemctl + ["disable", "--now", layout.serviceName], onlyIfPresent: service)
                : Command(systemctl + ["stop", layout.serviceName], onlyIfPresent: service))
        plan.removals = [service, timer, unit(layout, InstallLayout.rollbackServiceName)]
        if let autostart = layout.autostartDirectory {
            plan.removals.append(autostart + "/" + InstallLayout.autostartName)
        }
        if layout.scope == .system {
            plan.removals += [InstallLayout.polkitRuleFile, InstallLayout.sysusersFile]
        }
        plan.removesRoot = true
        plan.after = [Command(systemctl + ["daemon-reload"])]
        return plan
    }

    private static func systemctlPrefix(_ layout: InstallLayout) -> [String] {
        layout.scope == .system ? ["systemctl"] : ["systemctl", "--user"]
    }

    private static func unit(_ layout: InstallLayout, _ name: String) -> String {
        layout.unitDirectory + "/" + name
    }
}

/// The slot metadata in `state.json`: which slot is in use, and what each holds.
struct InstallState: Codable, Equatable {
    /// What one slot holds.
    struct Slot: Codable, Equatable {
        /// The payload's SHA-256, lowercase hex.
        var payloadSHA256: String
        /// The display version the payload reports.
        var versionLabel: String
    }

    /// The slot `current` points at.
    var active: String
    /// Each filled slot, by name.
    var slots: [String: Slot]

    /// The state after a fresh install of the payload hashing to `payloadSHA256` into slot `a`.
    static func fresh(payloadSHA256: String, versionLabel: String) -> InstallState {
        InstallState(active: "a", slots: ["a": Slot(payloadSHA256: payloadSHA256, versionLabel: versionLabel)])
    }

    /// The JSON written, keys sorted.
    func encoded() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return Array(try encoder.encode(self)) + [0x0A]
    }
}
