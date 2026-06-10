import Foundation

/// Pure presentation logic for the single Virtual Machine-menu guest-agent disk
/// item — the one place that maps (agent status, whether the installer disk is
/// attached) to a title, enabled state, and action.
///
/// Extracted from `AppDelegate.validateMenuItem` / `toggleGuestAgentDisk` so the
/// title/enablement/action stay in lockstep from a single source of truth and
/// are unit-testable — `validateMenuItem` itself is AppKit-bound and isn't.
/// Mirrors the static-classifier pattern in
/// `AgentStatusPopoverContentViewController`.
///
/// Scope note: this models only the status→item mapping. The hard gates that
/// disable the item regardless of status (no live VM for USB hot-plug, missing
/// bundled DMG) stay in `validateMenuItem`.
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

    /// Resolves the menu item for the given state.
    ///
    /// `isInstallerMounted` takes precedence (eject mode) over `status`:
    /// once the disk is attached the item always ejects, whatever the agent
    /// is doing. Otherwise the title is purpose-framed by status:
    /// Install/Update/Reinstall to attach for a missing/behind agent, "Manage"
    /// once it's present (re-attach to reinstall or run the bundled
    /// `uninstall.command`). `.unresponsive` is treated like `.current` — it
    /// persists when the user disables/uninstalls/kills the agent in the guest
    /// or switches login sessions, exactly when re-mounting is wanted. Only the
    /// genuinely-transient `.connecting` (self-resolves to `.current` or
    /// `.expectedMissing`) leaves the item disabled.
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
