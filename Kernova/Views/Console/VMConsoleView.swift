import SwiftUI

/// Console view that displays placeholder content when the VM display is popped out or fullscreen.
/// When the display is inline, the AppKit `VMDisplayBackingView` layer covers this view, so
/// the inline branch shows an inert black background.
struct VMConsoleView: View {
    @Bindable var instance: VMInstance

    var body: some View {
        VStack(spacing: 0) {
            if instance.displayMode == .fullscreen {
                ContentUnavailableView {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                } description: {
                    Text("The virtual machine display is in fullscreen mode.")
                } actions: {
                    Button("Exit Fullscreen") {
                        NSApp.sendAction(#selector(AppDelegate.toggleFullscreen(_:)), to: nil, from: nil)
                    }
                }
            } else if instance.displayMode == .popOut {
                ContentUnavailableView {
                    Label("Popped Out", systemImage: "pip.exit")
                } description: {
                    Text("The virtual machine display is in a separate window.")
                } actions: {
                    Button("Pop In") {
                        NSApp.sendAction(#selector(AppDelegate.togglePopOut(_:)), to: nil, from: nil)
                    }
                }
            } else if instance.isColdPaused {
                ContentUnavailableView(
                    "Suspended",
                    systemImage: "pause.circle",
                    description: Text("This virtual machine's state is saved to disk. Resume to continue.")
                )
            } else if instance.virtualMachine != nil {
                // Covered by the AppKit VMDisplayBackingView layer in DetailContainerViewController.
                Color.black
            } else {
                ContentUnavailableView(
                    "No Display",
                    systemImage: "display",
                    description: Text("The virtual machine display is not available.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
