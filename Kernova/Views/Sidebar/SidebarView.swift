import SwiftUI
import UniformTypeIdentifiers

/// Sidebar listing all virtual machines with status indicators.
struct SidebarView: View {
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        List(selection: $viewModel.selectedID) {
            Section("Virtual Machines") {
                ForEach(viewModel.instances) { instance in
                    VMRowView(
                        instance: instance,
                        isRenaming: viewModel.renamingInstanceID == instance.id,
                        onCommitRename: { newName in
                            viewModel.commitRename(for: instance, newName: newName)
                        },
                        onCancelRename: {
                            viewModel.cancelRename()
                        }
                    )
                    .tag(instance.id)
                    .contextMenu {
                        contextMenu(for: instance)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [.kernovaVM, .fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.pathExtension == VMStorageService.bundleExtension else { return }
                    Task { @MainActor in
                        viewModel.importVM(from: url)
                    }
                }
            }
            return true
        }
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

        Button("Rename") {
            viewModel.renameVM(instance)
        }
        .disabled(!instance.status.canEditSettings)

        Button("Clone") {
            Task { await viewModel.cloneVM(instance) }
        }
        .disabled(!instance.status.canEditSettings || viewModel.isCloning)

        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
        }

        Button("Move to Trash", role: .destructive) {
            viewModel.confirmDelete(instance)
        }
        .disabled(instance.status != .stopped)
    }
}
