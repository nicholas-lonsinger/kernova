import AppKit

/// Presents the detail pane's lifecycle confirmation alerts and the delete
/// sheet, driven by the view model's flags.
///
/// AppKit replacement for the SwiftUI `LifecycleAlerts` modifier (on the former
/// `VMDetailView`) plus the error / installer-mounted alerts that lived on
/// `MainDetailView`. Because these were hosted on the always-present SwiftUI
/// layer so they survived while the VM display was showing, the AppKit home is
/// here — owned by `DetailContainerViewController`, which is always present and
/// owns the window. One `ObservationLoop` watches the flags; each `false→true`
/// transition presents the matching alert (or the rich delete sheet) and resets
/// the flag on dismissal.
@MainActor
final class DetailAlertsPresenter: NSObject {
    private let viewModel: VMLibraryViewModel
    private weak var window: NSWindow?
    private let deleteSheetPresenter = SheetPresenter()
    private var observation: ObservationLoop?
    private var isShowingAlert = false

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func start(window: NSWindow) {
        self.window = window
        guard observation == nil else { return }
        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.viewModel.showDeleteConfirmation
                _ = self.viewModel.showDeleteSheet
                _ = self.viewModel.showCancelPreparingConfirmation
                _ = self.viewModel.showForceStopConfirmation
                _ = self.viewModel.showStopPausedConfirmation
                _ = self.viewModel.showError
                _ = self.viewModel.showInstallerMountedAlert
            },
            apply: { [weak self] in self?.apply() }
        )
        apply()
    }

    func stop() {
        observation?.cancel()
        observation = nil
        if deleteSheetPresenter.isShown { deleteSheetPresenter.close() }
    }

    // MARK: - Presentation

    private func apply() {
        guard let window, !isShowingAlert, !deleteSheetPresenter.isShown else { return }

        if viewModel.showDeleteSheet, let vm = viewModel.instanceToDelete {
            presentDeleteSheet(vm: vm, window: window)
            return
        }
        if viewModel.showDeleteConfirmation, let vm = viewModel.instanceToDelete {
            present(deleteConfirmationConfig(vm)) { [weak self] in
                self?.viewModel.showDeleteConfirmation = false
            }
            return
        }
        if viewModel.showCancelPreparingConfirmation, let instance = viewModel.preparingInstanceToCancel {
            present(cancelPreparingConfig(instance)) { [weak self] in
                self?.viewModel.showCancelPreparingConfirmation = false
            }
            return
        }
        if viewModel.showForceStopConfirmation, let vm = viewModel.instanceToForceStop {
            present(forceStopConfig(vm)) { [weak self] in
                self?.viewModel.showForceStopConfirmation = false
            }
            return
        }
        if viewModel.showStopPausedConfirmation, let vm = viewModel.instanceToStopPaused {
            present(stopPausedConfig(vm)) { [weak self] in
                self?.viewModel.showStopPausedConfirmation = false
            }
            return
        }
        if viewModel.showError, let message = viewModel.errorMessage {
            present(errorConfig(message)) { [weak self] in
                self?.viewModel.showError = false
            }
            return
        }
        if viewModel.showInstallerMountedAlert, let name = viewModel.installerMountedVMName {
            present(installerMountedConfig(name)) { [weak self] in
                self?.viewModel.showInstallerMountedAlert = false
            }
            return
        }
    }

    private func present(_ config: AlertConfiguration, reset: @escaping () -> Void) {
        guard let window else { return }
        isShowingAlert = true
        presentSheetAlert(config, in: window) { [weak self] in
            self?.isShowingAlert = false
            reset()
            // Another flag may have been set meanwhile; re-evaluate.
            self?.apply()
        }
    }

    private func presentDeleteSheet(vm: VMInstance, window: NSWindow) {
        let externals = viewModel.externalAttachments(for: vm)
        let content = DeleteVMSheetContentViewController(vmName: vm.name, externals: externals)
        content.delegate = self
        deleteSheetPresenter.onClose = { [weak self] in
            self?.viewModel.showDeleteSheet = false
            self?.viewModel.instanceToDelete = nil
            self?.apply()
        }
        deleteSheetPresenter.show(content: content, in: window)
    }

    // MARK: - Alert configurations (copied from the former SwiftUI modifiers)

    private func deleteConfirmationConfig(_ vm: VMInstance) -> AlertConfiguration {
        AlertConfiguration(
            title: "Delete Virtual Machine",
            message:
                "\"\(vm.name)\" will be moved to the Trash. You can restore it using Finder's Put Back command. Empty the Trash to permanently delete the VM and reclaim disk space.",
            buttons: [
                AlertButton("Move to Trash", role: .destructive) { [weak self] in
                    _ = self?.viewModel.deleteConfirmed(vm)
                },
                AlertButton("Cancel", role: .cancel),
            ])
    }

    private func cancelPreparingConfig(_ instance: VMInstance) -> AlertConfiguration {
        AlertConfiguration(
            title: instance.preparingState?.operation.cancelAlertTitle ?? "",
            message: "The operation will be stopped and any partially copied files will be removed.",
            buttons: [
                AlertButton(instance.preparingState?.operation.cancelLabel ?? "Cancel", role: .destructive) {
                    [weak self] in self?.viewModel.cancelPreparingConfirmed(instance)
                },
                AlertButton("Continue", role: .cancel),
            ])
    }

    private func forceStopConfig(_ vm: VMInstance) -> AlertConfiguration {
        var buttons: [AlertButton] = [
            AlertButton(vm.isColdPaused ? "Discard" : "Force Stop", role: .destructive) { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.forceStopConfirmed(vm) }
            }
        ]
        // Paused VMs route through the dedicated "Stop Paused" alert instead;
        // showing "Shut Down" here would chain a second alert on top of this one.
        if vm.canStop && vm.status != .paused {
            buttons.append(
                AlertButton("Shut Down", role: .default) { [weak self] in
                    self?.viewModel.stop(vm)
                })
        }
        buttons.append(AlertButton("Cancel", role: .cancel))
        return AlertConfiguration(
            title: vm.isColdPaused ? "Discard Saved State" : "Force Stop Virtual Machine",
            message: vm.isColdPaused
                ? "\"\(vm.name)\" has its state saved to disk. Discarding will permanently delete the saved state."
                : "\"\(vm.name)\" will be immediately terminated. Any unsaved data inside the guest will be lost.",
            buttons: buttons)
    }

    private func stopPausedConfig(_ vm: VMInstance) -> AlertConfiguration {
        // RATIONALE: This alert is itself a confirmation step, so "Force Stop"
        // intentionally calls forceStop directly rather than routing through
        // confirmForceStop and stacking a second alert. The message text makes
        // the destructive nature explicit so one confirmation is sufficient.
        AlertConfiguration(
            title: "Stop Paused Virtual Machine",
            message:
                "\"\(vm.name)\" is paused and cannot be shut down directly. Resume it to send a graceful shutdown, or force stop to terminate it immediately (any unsaved data inside the guest will be lost).",
            buttons: [
                AlertButton("Resume and Shut Down", role: .default) { [weak self] in
                    guard let self else { return }
                    Task { await self.viewModel.resumeAndStop(vm) }
                },
                AlertButton("Force Stop", role: .destructive) { [weak self] in
                    guard let self else { return }
                    Task { await self.viewModel.forceStopFromPaused(vm) }
                },
                AlertButton("Cancel", role: .cancel),
            ])
    }

    private func errorConfig(_ message: String) -> AlertConfiguration {
        AlertConfiguration(
            title: "Error", message: message, buttons: [AlertButton("OK", role: .cancel)])
    }

    private func installerMountedConfig(_ vmName: String) -> AlertConfiguration {
        AlertConfiguration(
            title: "Installer Mounted",
            message:
                "The Kernova guest agent installer has been attached to \(vmName) as a USB disk. Inside the VM, open the “Kernova Guest Agent” disk in Finder and run install.command to complete setup.",
            buttons: [AlertButton("OK", role: .cancel)])
    }
}

// MARK: - DeleteVMSheetContentViewControllerDelegate

extension DetailAlertsPresenter: DeleteVMSheetContentViewControllerDelegate {
    func deleteVMSheetDidCancel(_ vc: DeleteVMSheetContentViewController) {
        viewModel.showDeleteSheet = false
        viewModel.instanceToDelete = nil
        deleteSheetPresenter.close()
    }

    func deleteVMSheet(
        _ vc: DeleteVMSheetContentViewController, didConfirmTrashExternals trashExternals: Bool
    ) {
        if let vm = viewModel.instanceToDelete {
            _ = viewModel.deleteConfirmed(vm, trashExternals: trashExternals)
        }
        deleteSheetPresenter.close()
    }
}
