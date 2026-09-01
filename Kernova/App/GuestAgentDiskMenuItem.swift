import Foundation

/// Pure presentation logic for the single Virtual Machine-menu guest-agent disk
/// item — the one place that maps (agent status, whether the installer disk is
/// attached) to a title, enabled state, and action.
///
/// Models only the status→item mapping: the hard gates that disable the item
/// regardless of status (no live VM for USB hot-plug, missing bundled DMG) stay
/// in `MainMenuController.validate`.
enum GuestAgentDiskMenuItem {
    /// What clicking the item does in its current mode.
    enum Action: Equatable {
        /// The installer disk is attached — detach it.
        case eject
        /// The installer disk is not attached — attach it, framing the
        /// post-attach instructions alert by `purpose`.
        case mount(GuestAgentInstallerPurpose)
    }

    /// The item's resolved title, enabled state, and action.
    struct Model: Equatable {
        let title: String
        let isEnabled: Bool
        let action: Action
    }

    /// The title the item carries whenever a hard gate withholds the command,
    /// and the placeholder it is built with.
    ///
    /// A rejected item keeps whatever title the last accepted validation left
    /// on it, so the reject path has to retitle too: switching from a macOS
    /// guest with the disk attached to a Linux guest would otherwise strand
    /// "Eject Guest Agent Media" on a VM that can never have it.
    static let unavailableTitle = "Install Guest Agent…"

    /// Resolves the menu item for the given state.
    ///
    /// `isInstallerMounted` takes precedence (eject mode) over `status`: once the
    /// disk is attached the item always ejects, whatever the agent is doing.
    /// `.unresponsive` is treated like `.current` — it persists when the user
    /// disables, uninstalls or kills the agent in the guest, exactly when
    /// re-mounting is wanted — so only the genuinely-transient `.connecting`
    /// leaves the item disabled.
    static func model(status: AgentStatus, isInstallerMounted: Bool) -> Model {
        if isInstallerMounted {
            return Model(title: "Eject Guest Agent Media", isEnabled: true, action: .eject)
        }
        switch status {
        case .waiting:
            return Model(title: "Install Guest Agent…", isEnabled: true, action: .mount(.install))
        case .outdated:
            return Model(title: "Update Guest Agent…", isEnabled: true, action: .mount(.install))
        case .expectedMissing:
            return Model(title: "Reinstall Guest Agent…", isEnabled: true, action: .mount(.install))
        case .current, .unresponsive:
            return Model(title: "Manage Guest Agent…", isEnabled: true, action: .mount(.manage))
        case .connecting:
            return Model(title: "Install Guest Agent…", isEnabled: false, action: .mount(.install))
        }
    }
}
