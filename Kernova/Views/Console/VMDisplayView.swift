import SwiftUI
import Virtualization

/// `NSViewRepresentable` wrapping `VZVirtualMachineView` to display a running VM.
struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine?

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine

        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        if nsView.virtualMachine !== virtualMachine {
            nsView.virtualMachine = virtualMachine
        }
    }
}
