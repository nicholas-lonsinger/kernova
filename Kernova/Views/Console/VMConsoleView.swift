import SwiftUI

/// Console view that displays the VM screen, pause overlay, or a placeholder depending on VM state.
struct VMConsoleView: View {
    @Bindable var instance: VMInstance
    var onResume: () -> Void

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
                    .vmPauseOverlay(isPaused: instance.status == .paused, onResume: onResume)
                    .vmTransitionOverlay(status: instance.status)
            } else if instance.isColdPaused {
                ContentUnavailableView(
                    "Suspended",
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
