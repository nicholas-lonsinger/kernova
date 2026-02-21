import SwiftUI

/// Console view with the VM display and lifecycle control toolbar.
struct VMConsoleView: View {
    @Bindable var instance: VMInstance

    var body: some View {
        VStack(spacing: 0) {
            // VM Display
            if instance.isInFullscreen {
                ContentUnavailableView {
                    Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                } description: {
                    Text("The virtual machine display is in fullscreen mode.")
                } actions: {
                    Button("Exit Fullscreen") {
                        NSApp.sendAction(#selector(AppDelegate.toggleFullscreenDisplay(_:)), to: nil, from: nil)
                    }
                }
            } else if let vm = instance.virtualMachine {
                VMDisplayView(virtualMachine: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if instance.isColdPaused {
                ContentUnavailableView(
                    "Paused",
                    systemImage: "pause.circle",
                    description: Text("This virtual machine's state is saved to disk. Resume to continue.")
                )
            } else {
                ContentUnavailableView(
                    "No Display",
                    systemImage: "display",
                    description: Text("The virtual machine display is not available.")
                )
            }
        }
    }
}
