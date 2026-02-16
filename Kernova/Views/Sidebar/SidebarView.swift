import SwiftUI

/// Sidebar listing all virtual machines with status indicators.
struct SidebarView: View {
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        List(selection: $viewModel.selectedID) {
            Section("Virtual Machines") {
                ForEach(viewModel.instances) { instance in
                    VMRowView(instance: instance)
                        .tag(instance.id)
                        .contextMenu {
                            contextMenu(for: instance)
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func contextMenu(for instance: VMInstance) -> some View {
        if instance.status.canStart {
            Button("Start") {
                Task { await viewModel.start(instance) }
            }
        }
        if instance.status.canPause {
            Button("Pause") {
                Task { await viewModel.pause(instance) }
            }
        }
        if instance.status.canResume {
            Button("Resume") {
                Task { await viewModel.resume(instance) }
            }
        }
        if instance.status.canStop {
            Button("Stop") {
                viewModel.stop(instance)
            }
        }

        Divider()

        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
        }

        Button("Move to Trash", role: .destructive) {
            viewModel.confirmDelete(instance)
        }
        .disabled(instance.status != .stopped)
    }
}
