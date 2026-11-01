import KernovaAgentCore

/// Where one install scope's files go: the agent's own root, holding its two slots, and the units, autostart
/// entry, account and polkit rule that run it.
struct InstallLayout: Equatable, Sendable {
    /// `.user` or `.system`.
    let scope: InstallScope
    /// The agent's own root: `slots/a`, `slots/b`, the `current` link, `state.json`.
    let root: String
    /// Where its systemd units go.
    let unitDirectory: String
    /// User scope: the XDG autostart directory, which starts the session service at login.
    let autostartDirectory: String?

    /// The user scope, rooted at `root` (`LinuxIdentity.userInstallRoot(environment:)`), its units and
    /// autostart entry under `configHome` (``configHome(environment:)``).
    static func user(root: String, configHome: String) -> InstallLayout {
        InstallLayout(
            scope: .user, root: root, unitDirectory: configHome + "/systemd/user",
            autostartDirectory: configHome + "/autostart")
    }

    /// The system scope, rooted at `root` (`LinuxIdentity.systemInstallRoot`).
    static func system(root: String) -> InstallLayout {
        InstallLayout(scope: .system, root: root, unitDirectory: "/etc/systemd/system", autostartDirectory: nil)
    }

    /// `${XDG_CONFIG_HOME:-$HOME/.config}`; nil with neither set. A relative `XDG_CONFIG_HOME` is ignored, as
    /// the XDG Base Directory specification says.
    static func configHome(environment: [String: String]) -> String? {
        if let config = environment["XDG_CONFIG_HOME"], config.hasPrefix("/") { return config }
        guard let home = environment["HOME"], home.hasPrefix("/") else { return nil }
        return home + "/.config"
    }

    /// The variables `systemctl --user show-environment` prints, one `NAME=value` a line, a value holding
    /// anything but printable ASCII written as a `$'…'` string with backslash escapes.
    static func environment(parsingShowEnvironment text: String) -> [String: String] {
        var environment: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: equals)...]
            if value.hasPrefix("$'"), value.hasSuffix("'"), value.count >= 3 {
                value = value.dropFirst(2).dropLast()
                var unescaped = ""
                var escaping = false
                for character in value {
                    if escaping {
                        switch character {
                        case "n": unescaped.append("\n")
                        case "t": unescaped.append("\t")
                        default: unescaped.append(character)
                        }
                        escaping = false
                    } else if character == "\\" {
                        escaping = true
                    } else {
                        unescaped.append(character)
                    }
                }
                environment[String(line[..<equals])] = unescaped
            } else {
                environment[String(line[..<equals])] = String(value)
            }
        }
        return environment
    }

    /// The system peer's account.
    static let systemAccount = "kernova-agent"
    /// Declares ``systemAccount`` to systemd-sysusers.
    static let sysusersFile = "/etc/sysusers.d/kernova-agent.conf"
    /// Grants ``systemAccount`` the power actions.
    static let polkitRuleFile = "/etc/polkit-1/rules.d/50-kernova-agent.rules"

    /// The service that runs the peer.
    var serviceName: String { Self.serviceName(scope) }
    /// The service that runs the peer of `scope`.
    static func serviceName(_ scope: InstallScope) -> String {
        scope == .system ? "kernova-agent-system.service" : "kernova-agent.service"
    }
    static let rollbackTimerName = "kernova-agent-rollback.timer"
    static let rollbackServiceName = "kernova-agent-rollback.service"
    /// The user scope's autostart entry's file name.
    static let autostartName = "app.kernova.agent.desktop"

    /// The slot a fresh install fills.
    var installSlot: String { root + "/slots/a" }
    /// The link the units run the agent through, to the slot in use.
    var current: String { root + "/" + Self.currentLinkName }
    /// What `current` points at after a fresh install, relative to ``root``.
    static let installSlotLink = "slots/a"
    /// The slot metadata.
    var state: String { root + "/" + Self.stateName }
    /// Present exactly while an update's switch is unconfirmed; the rollback service runs only then.
    var switchPending: String { root + "/" + Self.switchPendingName }
    static let switchPendingName = "switch-pending"
    /// Present from the moment the rollback check reverts a switch until the agent it restarts records the
    /// switch's payload as rejected.
    var switchRejected: String { root + "/" + Self.switchRejectedName }
    static let switchRejectedName = "switch-rejected"
    /// The link to the previous slot, whose binary the rollback service runs.
    var rollback: String { root + "/" + Self.rollbackLinkName }
    static let rollbackLinkName = "rollback"
    /// `current`'s name in the root.
    static let currentLinkName = "current"
    /// `state.json`'s name in the root.
    static let stateName = "state.json"
    /// The binary's name in every slot.
    static let binaryName = "kernova-agent"
}
