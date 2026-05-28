import Foundation

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
    /// Show the unified delete sheet: the VM's in-bundle disks (removed with
    /// the VM) plus any external files, each individually selectable for
    /// trashing. Used for every delete.
    func presentDeleteSheet(for instance: VMInstance)
    /// Show the force-stop / discard-saved-state confirmation.
    func presentForceStop(for instance: VMInstance)
    /// Show the stop-paused confirmation (resume-and-shut-down vs. force stop).
    func presentStopPaused(for instance: VMInstance)
    /// Show the cancel-preparing (clone/import) confirmation.
    func presentCancelPreparing(for instance: VMInstance)
    /// Show the "guest agent installer mounted, here are the next steps" alert.
    func presentInstallerMounted(vmName: String)
    /// Present the VM creation wizard sheet.
    func presentCreationWizard()
}
