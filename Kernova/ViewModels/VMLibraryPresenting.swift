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
/// Never built for the disk the guest boots from — a VM can't meaningfully
/// start without it.
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
@MainActor
protocol VMLibraryPresenting: AnyObject {
    /// Show an error alert headed `title` with `message`.
    func presentError(_ message: String, title: String)
    /// Show the start-failed alert for an attachment that couldn't be opened,
    /// offering to remove it from the configuration and start again.
    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance)
    /// Show the unified delete sheet: the VM's in-bundle disks plus any external
    /// files, each individually selectable for deletion. `permanently` selects
    /// the immediate (bypass-Trash) variant.
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
    /// Move keyboard focus into `instance`'s inline guest display, called at
    /// the moment a user action routes the display there (start, resume, pop
    /// in). If the display is not up yet, the request holds until it appears —
    /// but expires the instant focus moves anywhere else, so it never steals
    /// focus later.
    func focusGuestDisplay(for instance: VMInstance)
}
