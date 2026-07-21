import Foundation

/// Why the guest-agent installer disk was attached, so the post-mount alert can
/// point the user at the right next step.
enum GuestAgentInstallerPurpose: Equatable {
    /// The agent is absent or behind the bundled version — a fresh install,
    /// update, or reinstall. The user runs `install.command`.
    case install
    /// The agent is already installed (`.current`) or present-but-unresponsive
    /// — the user re-mounted the disk to reinstall *or* run `uninstall.command`.
    case manage
}

/// A start attempt that failed because one attachment couldn't be opened,
/// where removing that attachment (detach only — the file is untouched) is a
/// valid way to get the VM running again.
///
/// Built by `VMLibraryViewModel` from `ConfigurationBuilderError`'s attach
/// failures; never built for the disk the guest boots from (a VM can't
/// meaningfully start without it). All attachment kinds are treated
/// uniformly — a stale guest-agent installer entry, a moved ISO, and an
/// external disk with a dead bookmark all surface the same offer.
struct StartFailedAttachment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case storageDisk
        case removableMedia
    }

    let kind: Kind
    /// The failing item's ID in the VM's configuration, so the removal targets
    /// exactly the entry that failed even if the list changed since.
    let id: UUID
    let label: String
    /// The full user-facing error description (item, path, likely cause).
    let message: String
}

/// Imperative presentation interface the view model calls to surface alerts,
/// sheets, and the creation wizard.
///
/// Replaces the former observed `show*` boolean flags on `VMLibraryViewModel`.
/// Instead of flipping observable state and having a presenter react to it, the
/// view model calls these methods directly. `DetailContainerViewController` (the
/// always-present window owner) implements them — forwarding alerts and the
/// delete sheet to `DetailAlertsPresenter` and owning the wizard sheet itself.
@MainActor
protocol VMLibraryPresenting: AnyObject {
    /// Show a generic error alert with `message`.
    func presentError(_ message: String)
    /// Show the start-failed alert for an attachment that couldn't be opened,
    /// offering to remove it from the configuration and start again.
    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance)
    /// Show the unified delete sheet: the VM's in-bundle disks (removed with
    /// the VM) plus any external files, each individually selectable for
    /// deletion. Used for every delete. `permanently` selects the immediate
    /// (bypass-Trash) variant, which the sheet reflects in its wording and
    /// confirm button.
    func presentDeleteSheet(for instance: VMInstance, permanently: Bool)
    /// Show the force-stop / discard-saved-state confirmation.
    func presentForceStop(for instance: VMInstance)
    /// Show the confirmation for booting a macOS guest into macOS Recovery.
    func presentRecoveryBoot(for instance: VMInstance)
    /// Show the stop-paused confirmation (resume-and-shut-down vs. force stop).
    func presentStopPaused(for instance: VMInstance)
    /// Show the cancel-preparing (clone/import) confirmation.
    func presentCancelPreparing(for instance: VMInstance)
    /// Show the "guest agent disk attached, here are the next steps" alert,
    /// worded for `purpose` (install vs. install-or-uninstall).
    func presentInstallerMounted(vmName: String, purpose: GuestAgentInstallerPurpose)
    /// Present the VM creation wizard sheet.
    func presentCreationWizard()
}
