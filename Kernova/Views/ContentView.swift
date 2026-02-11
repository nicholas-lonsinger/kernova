import SwiftUI

/// Detail pane showing the selected VM or a placeholder.
/// Navigation split is now handled at the AppKit level via `NSSplitViewController`.
struct ContentView: View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showCreationWizard = true
                } label: {
                    Label("New VM", systemImage: "plus")
                }
                .help("Create a new virtual machine")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
