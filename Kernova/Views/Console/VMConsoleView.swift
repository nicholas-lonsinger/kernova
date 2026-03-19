import SwiftUI

/// Console view with the VM display and lifecycle control toolbar.
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if instance.status == .paused {
                            VMPauseOverlay(onResume: onResume)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: instance.status == .paused)
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
    }
}
