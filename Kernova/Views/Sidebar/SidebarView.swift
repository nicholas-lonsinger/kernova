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
        if let preparing = instance.preparingState {
            Button(preparing.operation.cancelLabel) {
                viewModel.confirmCancelPreparing(instance)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
            }
        } else {
            // Lifecycle
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
            if instance.status.canForceStop && !instance.status.canStop {
                Button("Force Stop") {
                    viewModel.confirmForceStop(instance)
                }
            }

            // State
            if instance.status.canSave && !instance.isColdPaused {
                Divider()
                Button("Save State") {
                    Task { await viewModel.save(instance) }
                }
            }

            // Display
            if instance.status.canStop && instance.virtualMachine != nil {
                Divider()
                Button("Fullscreen Display") {
                    NSApp.sendAction(#selector(AppDelegate.toggleFullscreenDisplay(_:)), to: nil, from: nil)
                }
            }

            Divider()

            // Management
            Button("Rename") {
                viewModel.renameVM(instance)
            }
            .disabled(!instance.status.canEditSettings)

            Button("Clone") {
                viewModel.cloneVM(instance)
            }
            .disabled(!instance.status.canEditSettings || viewModel.hasPreparing)

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
            }

            Divider()

            // Destructive
            Button("Move to Trash", role: .destructive) {
                viewModel.confirmDelete(instance)
            }
            .disabled(!instance.status.canEditSettings)
        }
    }
}
