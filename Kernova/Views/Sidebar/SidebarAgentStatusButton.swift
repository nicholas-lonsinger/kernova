import AppKit
import SwiftUI

/// Trailing accessory shown in the sidebar row when the guest agent needs
/// the user's attention — either it's not installed, the installed version
/// is older than what this build of Kernova bundles, or it stopped
/// responding.
///
/// SwiftUI shim over the AppKit ``SidebarAgentStatusButtonView``. The shim
/// exists so the SwiftUI call site in `VMRowView` keeps the same
/// `SidebarAgentStatusButton(vmName:status:onMount:onDismiss:)` initializer
/// surface during the incremental SwiftUI→AppKit transition.
///
/// All of the rendering — the SF Symbol button, the spinner used during
/// the `.connecting` state, and the click-to-open `NSPopover` — is AppKit.
/// `onMount` is invoked when the user clicks the popover's action button
/// for a status that requires mounting the installer (`.waiting`,
/// `.outdated`, `.expectedMissing`); the other states just close the
/// popover on action. `onDismiss`, when supplied, surfaces a "Don't show
/// again" link in the popover (wired only for `.waiting` — the other
/// states are too urgent to dismiss).
struct SidebarAgentStatusButton: NSViewRepresentable {
    let vmName: String
    let status: AgentStatus
    let onMount: () -> Void
    let onDismiss: (() -> Void)?

    func makeNSView(context: Context) -> SidebarAgentStatusButtonView {
        let view = SidebarAgentStatusButtonView()
        view.onMount = onMount
        view.onDismiss = onDismiss
        view.configure(
            status: status, vmName: vmName, hasDismissAction: onDismiss != nil
        )
        return view
    }

    func updateNSView(_ view: SidebarAgentStatusButtonView, context: Context) {
        view.onMount = onMount
        view.onDismiss = onDismiss
        view.configure(
            status: status, vmName: vmName, hasDismissAction: onDismiss != nil
        )
    }
}
