import SwiftUI

/// Detail area that switches between settings, console, install progress, and transition views based on VM status.
struct VMDetailView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        Group {
            if let preparing = instance.preparingState {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(preparing.operation.displayLabel)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch instance.status {
                case .stopped, .error:
                    VMSettingsView(instance: instance, viewModel: viewModel)

                case .installing:
                    if let installState = instance.installState {
                        MacOSInstallProgressView(installState: installState) {
                            viewModel.cancelInstallation(instance)
                        }
                    } else {
                        transitionView
                    }

                case .running, .paused:
                    VMConsoleView(instance: instance) {
                        Task { await viewModel.resume(instance) }
                    }

                default:
                    transitionView
                }
            }
        }
        .navigationTitle(instance.name)
        .alert(
            "Delete Virtual Machine",
            isPresented: $viewModel.showDeleteConfirmation,
            presenting: viewModel.instanceToDelete
        ) { vm in
            Button("Move to Trash", role: .destructive) {
                viewModel.deleteConfirmed(vm)
            }
            Button("Cancel", role: .cancel) {}
        } message: { vm in
            Text("\"\(vm.name)\" will be moved to the Trash. You can restore it using Finder's Put Back command. Empty the Trash to permanently delete the VM and reclaim disk space.")
        }
        .alert(
            viewModel.preparingInstanceToCancel?.preparingState?.operation.cancelAlertTitle ?? "",
            isPresented: $viewModel.showCancelPreparingConfirmation,
            presenting: viewModel.preparingInstanceToCancel
        ) { instance in
            Button(instance.preparingState?.operation.cancelLabel ?? "Cancel", role: .destructive) {
                viewModel.cancelPreparingConfirmed(instance)
            }
            Button("Continue", role: .cancel) {}
        } message: { _ in
            Text("The operation will be stopped and any partially copied files will be removed.")
        }
        .alert(
            "Force Stop Virtual Machine",
            isPresented: $viewModel.showForceStopConfirmation,
            presenting: viewModel.instanceToForceStop
        ) { vm in
            Button("Force Stop", role: .destructive) {
                Task { await viewModel.forceStopConfirmed(vm) }
            }
            if vm.status.canStop {
                Button("Shut Down") {
                    viewModel.stop(vm)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { vm in
            Text("\"\(vm.name)\" will be immediately terminated. Any unsaved data inside the guest will be lost.")
        }
    }

    private var transitionView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(instance.status.displayName)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
