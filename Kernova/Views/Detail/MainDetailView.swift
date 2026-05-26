import SwiftUI

/// Detail pane content that switches between VM detail and an empty state.
///
/// Hosts the error alerts. The creation wizard is presented separately as a
/// pure-AppKit sheet by `DetailContainerViewController`.
struct MainDetailView: View {
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        Group {
            if let selected = viewModel.selectedInstance {
                VMDetailView(instance: selected, viewModel: viewModel)
                    // RATIONALE: Tie SwiftUI view identity to the selected VM so all
                    // per-VM transient @State in the detail subtree (settings popovers,
                    // alerts, rename fields, focus, picker defaults) resets on a sidebar
                    // switch. The AppKit VMDisplayBackingView layer in
                    // DetailContainerViewController is keyed separately by `instance.id`
                    // and is not affected by this rebuild.
                    .id(selected.id)
            } else {
                ContentUnavailableView {
                    Label("No Virtual Machine Selected", systemImage: "desktopcomputer")
                } description: {
                    Text("Select a virtual machine from the sidebar or create a new one.")
                } actions: {
                    Button("New Virtual Machine") {
                        viewModel.showCreationWizard = true
                    }
                }
            }
        }
        .sheetAlert(
            isPresented: $viewModel.showError,
            presenting: viewModel.errorMessage
        ) { message in
            AlertConfiguration(
                title: "Error",
                message: message,
                buttons: [AlertButton("OK", role: .cancel)]
            )
        }
        .sheetAlert(
            isPresented: $viewModel.showInstallerMountedAlert,
            presenting: viewModel.installerMountedVMName
        ) { vmName in
            AlertConfiguration(
                title: "Installer Mounted",
                message:
                    "The Kernova guest agent installer has been attached to \(vmName) as a USB disk. Inside the VM, open the “Kernova Guest Agent” disk in Finder and run install.command to complete setup.",
                buttons: [AlertButton("OK", role: .cancel)]
            )
        }
    }
}
