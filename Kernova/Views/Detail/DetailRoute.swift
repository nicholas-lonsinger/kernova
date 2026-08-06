import Foundation

/// Which content the detail pane shows for a given VM, derived purely from the
/// VM's status and related flags.
enum DetailRoute: Equatable {
    /// A clone/import is in progress; show a spinner with `label`.
    case preparing(label: String)
    /// Show the settings form. `isReadOnly` is `true` when viewing a running
    /// VM's configuration.
    case settings(isReadOnly: Bool)
    /// VM exists but hasn't completed its initial boot; show the initial-boot
    /// banner stacked above the (editable) settings form.
    case initialBoot
    /// The VM's last operation failed permanently; show the error banner
    /// carrying `message` above the (editable) settings form.
    ///
    /// The message is part of the route so a second failure with different text
    /// re-renders rather than comparing equal to the first.
    case error(message: String?)
    /// A guest setup is running; show the setup-progress UI.
    case setup
    /// A transient status (starting, suspending, restoring, …) with no editable
    /// content yet; show a spinner with `label`.
    case transition(label: String)
    /// The VM has a live display and the user has the display pane selected.
    case display

    /// Resolves the route the detail pane should display.
    ///
    /// A preparing operation wins over every status; `preparingLabel` is
    /// `preparingState?.operation.displayLabel`, or `nil` when none is running.
    static func resolve(
        preparingLabel: String?,
        status: VMStatus,
        errorMessage: String?,
        hasSetupState: Bool,
        detailPaneMode: DetailPaneMode
    ) -> DetailRoute {
        if let preparingLabel {
            return .preparing(label: preparingLabel)
        }
        switch status {
        case .stopped:
            return .settings(isReadOnly: false)
        case .error:
            return .error(message: errorMessage)
        case .initialBoot:
            return .initialBoot
        case .installing:
            return hasSetupState ? .setup : .transition(label: status.displayName)
        default:
            if status.hasActiveDisplay {
                return detailPaneMode == .settings ? .settings(isReadOnly: true) : .display
            }
            return .transition(label: status.displayName)
        }
    }
}
