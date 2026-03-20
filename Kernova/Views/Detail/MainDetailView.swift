import SwiftUI

/// Detail pane content that switches between VM detail and an empty state,
/// and hosts the creation wizard sheet and error alert.
struct MainDetailView: View {
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        Group {
            if let selected = viewModel.selectedInstance {
                VMDetailView(instance: selected, viewModel: viewModel)
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
        .sheet(isPresented: $viewModel.showCreationWizard) {
            VMCreationWizardView(viewModel: viewModel)
        }
        .alert(
            "Error",
            isPresented: $viewModel.showError,
            presenting: viewModel.errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}
