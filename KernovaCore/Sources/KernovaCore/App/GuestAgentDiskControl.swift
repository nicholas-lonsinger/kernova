import Foundation
import KernovaCommandModel

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
        /// The command the user runs inside the guest to install from the
        /// attached disk, for a disk opened from a terminal rather than in
        /// Finder: the Linux agent's, while it is attached.
        package var installCommand: String?

        init(title: String, isEnabled: Bool, action: Action, installCommand: String? = nil) {
            self.title = title
            self.isEnabled = isEnabled
            self.action = action
            self.installCommand = installCommand
        }
    }

    /// The title the item carries whenever a hard gate withholds the command,
    /// and the placeholder it is built with.
    ///
    /// A rejected item keeps whatever title the last accepted validation left
    /// on it, so the reject path has to retitle too: switching from a VM with
    /// the disk attached to one that is stopped would otherwise strand "Eject
    /// Guest Agent Media" on a VM that cannot have it.
    package static let unavailableTitle = "Install Guest Agent…"

    /// The control while the command is withheld.
    private static let withheld = Model(
        title: unavailableTitle, isEnabled: false, action: .mount(.install))

    /// Resolves the control for `instance` now: disabled under
    /// ``unavailableTitle`` while `capabilities` refuses the command or no
    /// installer disk is bundled for the VM's guest OS, and otherwise the
    /// status mapping of ``model(status:isInstallerMounted:)``, with the
    /// Linux disk's ``Model/installCommand`` while it is attached.
    @MainActor
    package static func model(
        for instance: VMInstance, in capabilities: VMCapabilityCatalog
    ) -> Model {
        let guestOS = instance.configuration.guestOS
        guard capabilities.isAvailable(.toggleGuestAgentDisk, on: instance),
            instance.bundleProducts.guestAgents.bundlesInstallerDisk(for: guestOS)
        else {
            return withheld
        }
        var model = model(
            status: instance.agentPresentation?.status,
            isInstallerMounted: instance.hasGuestAgentInstallerMounted)
        if model.action == .eject, guestOS == .linux {
            model.installCommand = LinuxAgentDisk.installCommand
        }
        return model
    }

    /// Resolves the control for the given state.
    ///
    /// `isInstallerMounted` takes precedence (eject mode) over `status`: once the
    /// disk is attached the control always ejects, whatever the agent is doing.
    /// `.unresponsive` is treated like `.current` — it persists when the user
    /// disables, uninstalls or kills the agent in the guest, exactly when
    /// re-mounting is wanted — so only the genuinely-transient `.connecting`
    /// and `.updating` leave the control disabled: an agent updating itself
    /// needs nothing installed. A `nil` `status` — no session, so no agent to
    /// install into — disables it under ``unavailableTitle``.
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
        case .current, .connected, .unresponsive:
            return Model(title: "Manage Guest Agent…", isEnabled: true, action: .mount(.manage))
        case .updating:
            return Model(title: "Manage Guest Agent…", isEnabled: false, action: .mount(.manage))
        case .connecting:
            return Model(title: "Install Guest Agent…", isEnabled: false, action: .mount(.install))
        }
    }
}
