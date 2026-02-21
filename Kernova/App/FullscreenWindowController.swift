import Cocoa
import SwiftUI
import Virtualization

/// Manages a dedicated fullscreen window displaying a single VM's screen.
///
/// On show the inline `VMDisplayView` in the main window is replaced by a placeholder
/// (via `VMInstance.isInFullscreen`), and this controller creates its own
/// `VZVirtualMachineView` bound to the same `VZVirtualMachine`. On close the process
/// reverses so the inline display re-appears.
@MainActor
final class FullscreenWindowController: NSWindowController, NSWindowDelegate {

    let vmID: UUID
    private let instance: VMInstance
    private var observingStatus = false

    init(instance: VMInstance) {
        self.vmID = instance.instanceID
        self.instance = instance

        let contentView = FullscreenVMView(instance: instance)
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "\(instance.name) — Display"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenPrimary]

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        instance.isInFullscreen = true
        super.showWindow(sender)
        window?.toggleFullScreen(nil)
        observeStatus()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        observingStatus = false
        instance.isInFullscreen = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // User pressed Esc or swiped to exit macOS fullscreen — close the window entirely
        window?.close()
    }

    // MARK: - Status Observation

    /// Automatically closes the fullscreen window when the VM stops or errors out.
    private func observeStatus() {
        observingStatus = true
        withObservationTracking {
            _ = self.instance.status
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observingStatus else { return }
                let status = self.instance.status
                if status == .stopped || status == .error {
                    self.window?.close()
                } else {
                    self.observeStatus()
                }
            }
        }
    }
}

// MARK: - Fullscreen SwiftUI View

/// SwiftUI view used inside the fullscreen window. Shows the VM display when a
/// `VZVirtualMachine` is available, or a placeholder otherwise.
private struct FullscreenVMView: View {
    let instance: VMInstance

    var body: some View {
        if let vm = instance.virtualMachine {
            VMDisplayView(virtualMachine: vm)
                .ignoresSafeArea()
        } else {
            ContentUnavailableView(
                "No Display",
                systemImage: "display",
                description: Text("The virtual machine display is not available.")
            )
        }
    }
}
