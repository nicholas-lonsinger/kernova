import SwiftUI

/// Detail area that switches between settings, console, install progress, and transition views based on VM status.
struct VMDetailView: View {
    @Bindable var instance: VMInstance
    @Bindable var viewModel: VMLibraryViewModel

    var body: some View {
        content
            .modifier(LifecycleAlerts(viewModel: viewModel))
    }

    @ViewBuilder
    private var content: some View {
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
                VMSettingsView(instance: instance, viewModel: viewModel, isReadOnly: false)

            case .installing:
                if let installState = instance.installState {
                    MacOSInstallProgressView(installState: installState) {
                        viewModel.cancelInstallation(instance)
                    }
                } else {
                    transitionView
                }

            case _ where instance.status.hasActiveDisplay:
                if instance.detailPaneMode == .settings {
                    VMSettingsView(instance: instance, viewModel: viewModel, isReadOnly: true)
                } else {
                    VMConsoleView(instance: instance)
                }

            default:
                transitionView
            }
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

/// Lifecycle confirmation alerts (delete, cancel preparing, force stop, stop paused).
/// Extracted into a separate modifier to keep the parent `body` expression within
/// the Swift type-checker's complexity budget.
private struct LifecycleAlerts: ViewModifier {
    @Bindable var viewModel: VMLibraryViewModel

    func body(content: Content) -> some View {
        content
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
                viewModel.instanceToForceStop?.isColdPaused == true
                    ? "Discard Saved State"
                    : "Force Stop Virtual Machine",
                isPresented: $viewModel.showForceStopConfirmation,
                presenting: viewModel.instanceToForceStop
            ) { vm in
                Button(vm.isColdPaused ? "Discard" : "Force Stop", role: .destructive) {
                    Task { await viewModel.forceStopConfirmed(vm) }
                }
                // Paused VMs route through the dedicated "Stop Paused" alert instead;
                // showing "Shut Down" here would chain a second alert on top of this one.
                if vm.canStop && vm.status != .paused {
                    Button("Shut Down") {
                        viewModel.stop(vm)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { vm in
                if vm.isColdPaused {
                    Text("\"\(vm.name)\" has its state saved to disk. Discarding will permanently delete the saved state.")
                } else {
                    Text("\"\(vm.name)\" will be immediately terminated. Any unsaved data inside the guest will be lost.")
                }
            }
            .alert(
                "Stop Paused Virtual Machine",
                isPresented: $viewModel.showStopPausedConfirmation,
                presenting: viewModel.instanceToStopPaused
            ) { vm in
                Button("Resume and Shut Down") {
                    Task { await viewModel.resumeAndStop(vm) }
                }
                // RATIONALE: This alert is itself a confirmation step, so
                // "Force Stop" intentionally calls forceStop directly rather
                // than routing through confirmForceStop and stacking a second
                // alert. The message text below makes the destructive nature
                // explicit so one confirmation is sufficient.
                Button("Force Stop", role: .destructive) {
                    Task { await viewModel.forceStopFromPaused(vm) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { vm in
                Text("\"\(vm.name)\" is paused and cannot be shut down directly. Resume it to send a graceful shutdown, or force stop to terminate it immediately (any unsaved data inside the guest will be lost).")
            }
    }
}
