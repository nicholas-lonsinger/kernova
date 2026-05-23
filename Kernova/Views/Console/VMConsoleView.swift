import AppKit
import SwiftUI

/// SwiftUI shim over the AppKit ``VMConsoleContentViewController``.
///
/// `VMDetailView` mounts this view whenever a running VM is showing its
/// "display" pane but the actual VM display is unavailable for the current
/// `VMInstance` — fullscreen, popped out, cold-paused ("Suspended"), or no
/// virtual machine attached. All rendering, layout, and lifecycle observation
/// is AppKit; the SwiftUI side exists only to preserve the existing
/// `VMConsoleView(instance:)` call surface during the incremental
/// SwiftUI→AppKit transition.
///
/// When the display is inline and the VM is running, the AppKit
/// `VMDisplayBackingView` layer covers this view, so the placeholder is
/// hidden and the controller paints an inert black background.
struct VMConsoleView: NSViewControllerRepresentable {
    let instance: VMInstance

    func makeNSViewController(context: Context) -> VMConsoleContentViewController {
        VMConsoleContentViewController(instance: instance)
    }

    func updateNSViewController(_ controller: VMConsoleContentViewController, context: Context) {
        controller.reconfigure(instance: instance)
    }
}
