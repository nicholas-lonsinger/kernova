import Foundation

/// Which content the detail pane shows for a given VM, derived purely from the
/// VM's status and related flags.
///
/// This is the AppKit replacement for the `switch` in the former SwiftUI
/// `VMDetailView`. Extracting it as a pure value + mapping function keeps the
/// routing logic unit-testable independently of `VMDetailRouterViewController`,
/// which simply swaps its visible child to match the resolved route.
enum DetailRoute: Equatable {
    /// A clone/import is in progress; show a spinner with `label`.
    case preparing(label: String)
    /// Show the settings form. `isReadOnly` is `true` when viewing a running
    /// VM's configuration.
    case settings(isReadOnly: Bool)
    /// VM exists but hasn't completed its initial boot; show the initial-boot
    /// banner stacked above the (editable) settings form.
    case initialBoot
    /// A macOS install is running; show the install-progress UI.
    case install
    /// A transient status (starting, suspending, restoring, …) with no editable
    /// content yet; show a spinner with `label`.
    case transition(label: String)
    /// The VM has a live display and the user has the display pane selected.
    case display

    /// Resolves the route from the decomposed inputs that drove the SwiftUI router.
    ///
    /// Mirrors the SwiftUI router's precedence exactly:
    ///
    /// 1. A preparing operation wins over everything (it has its own label).
    /// 2. Stopped/error → editable settings.
    /// 3. Initial boot → banner + editable settings.
    /// 4. Installing → install UI when an install state exists, else a transition.
    /// 5. Otherwise, when the VM has an active display, honor the chosen pane
    ///    (read-only settings vs. display); any other status is a transition.
    ///
    /// - Parameters:
    ///   - preparingLabel: `preparingState?.operation.displayLabel`, or `nil`.
    ///   - status: the VM's runtime status.
    ///   - hasInstallState: whether `installState` is non-nil.
    ///   - detailPaneMode: the user's chosen pane for a running VM.
    /// - Returns: The ``DetailRoute`` the detail pane should display.
    static func resolve(
        preparingLabel: String?,
        status: VMStatus,
        hasInstallState: Bool,
        detailPaneMode: DetailPaneMode
    ) -> DetailRoute {
        if let preparingLabel {
            return .preparing(label: preparingLabel)
        }
        switch status {
        case .stopped, .error:
            return .settings(isReadOnly: false)
        case .initialBoot:
            return .initialBoot
        case .installing:
            return hasInstallState ? .install : .transition(label: status.displayName)
        default:
            if status.hasActiveDisplay {
                return detailPaneMode == .settings ? .settings(isReadOnly: true) : .display
            }
            return .transition(label: status.displayName)
        }
    }
}
