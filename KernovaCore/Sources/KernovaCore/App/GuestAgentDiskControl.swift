import Foundation

/// The guest-agent disk control every surface offers — the Virtual Machine menu
/// item, the sidebar agent popover, the Clipboard window's footer — and the one
/// place that resolves a VM's title, enabled state, and action for it.
///
/// Every surface resolves through ``model(for:in:)``, which withholds the
/// control wherever admission refuses ``VMCapability/toggleGuestAgentDisk`` or
/// the build bundles no installer disk, so no surface offers a click the verb
/// refuses.
package enum GuestAgentDiskControl {
    /// What clicking the control does in its current mode.
    enum Action: Equatable {
        /// The installer disk is attached — detach it.
        case eject
        /// The installer disk is not attached — attach it, framing the
        /// post-attach instructions alert by `purpose`.
        case mount(GuestAgentInstallerPurpose)
    }

    /// The control's resolved title, enabled state, and action.
    package struct Model: Equatable {
        package let title: String
        package let isEnabled: Bool
        let action: Action
    }

    /// The title the item carries whenever a hard gate withholds the command,
    /// and the placeholder it is built with.
    ///
    /// A rejected item keeps whatever title the last accepted validation left
    /// on it, so the reject path has to retitle too: switching from a macOS
    /// guest with the disk attached to a Linux guest would otherwise strand
    /// "Eject Guest Agent Media" on a VM that can never have it.
    package static let unavailableTitle = "Install Guest Agent…"

    /// The control while the command is withheld.
    private static let withheld = Model(
        title: unavailableTitle, isEnabled: false, action: .mount(.install))

    /// Resolves the control for `instance` now: disabled under
    /// ``unavailableTitle`` while `capabilities` refuses the command or no
    /// installer disk is bundled, and otherwise the status mapping of
    /// ``model(status:isInstallerMounted:)``.
    @MainActor
    package static func model(
        for instance: VMInstance, in capabilities: VMCapabilityCatalog
    ) -> Model {
        guard capabilities.isAvailable(.toggleGuestAgentDisk, on: instance),
            instance.bundleProducts.guestAgent.installerDiskImageURL != nil
        else {
            return withheld
        }
        return model(
            status: instance.agentPresentation?.status,
            isInstallerMounted: instance.hasGuestAgentInstallerMounted)
    }

    /// Resolves the control for the given state.
    ///
    /// `isInstallerMounted` takes precedence (eject mode) over `status`: once the
    /// disk is attached the control always ejects, whatever the agent is doing.
    /// `.unresponsive` is treated like `.current` — it persists when the user
    /// disables, uninstalls or kills the agent in the guest, exactly when
    /// re-mounting is wanted — so only the genuinely-transient `.connecting`
    /// leaves the control disabled. A `nil` `status` — no session, so no agent
    /// to install into — disables it under ``unavailableTitle``.
    static func model(status: AgentStatus?, isInstallerMounted: Bool) -> Model {
        if isInstallerMounted {
            return Model(title: "Eject Guest Agent Media", isEnabled: true, action: .eject)
        }
        guard let status else { return withheld }
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
