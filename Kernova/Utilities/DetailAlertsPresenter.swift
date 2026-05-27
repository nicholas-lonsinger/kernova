import AppKit

/// Presents the detail pane's lifecycle confirmation alerts and the delete
/// sheet on behalf of `DetailContainerViewController`.
///
/// AppKit replacement for the SwiftUI `LifecycleAlerts` modifier (on the former
/// `VMDetailView`) plus the error / installer-mounted alerts that lived on
/// `MainDetailView`. These are owned by `DetailContainerViewController` — which
/// is always present and owns the window — so they survive while the VM display
/// is showing.
///
/// Presentation is imperative: the container forwards each request here. One
/// alert/sheet shows at a time; requests that arrive while one is up (or before
/// the window exists) are queued and run in order.
@MainActor
final class DetailAlertsPresenter: NSObject {
    private let viewModel: VMLibraryViewModel
    private weak var window: NSWindow?
    private let deleteSheetPresenter = SheetPresenter()
    private var isShowingAlert = false
    /// The VM the delete sheet is currently presenting for, read by the sheet
    /// delegate on confirm.
    private var deleteSheetInstance: VMInstance?
    /// Presentation requests deferred because the presenter was busy (an alert
    /// or sheet was up) or had no window yet; drained in order once free.
    private var pending: [(DetailAlertsPresenter) -> Void] = []

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func start(window: NSWindow) {
        self.window = window
        runNext()
    }

    func stop() {
        if deleteSheetPresenter.isShown { deleteSheetPresenter.close() }
        pending.removeAll()
    }

    // MARK: - Imperative presentation

    func presentError(_ message: String) {
        enqueue { $0.present($0.errorConfig(message)) }
    }

    func presentDeleteConfirmation(for instance: VMInstance) {
        enqueue { $0.present($0.deleteConfirmationConfig(instance)) }
    }

    func presentDeleteSheet(for instance: VMInstance) {
        enqueue { $0.showDeleteSheet(for: instance) }
    }

    func presentForceStop(for instance: VMInstance) {
        enqueue { $0.present($0.forceStopConfig(instance)) }
    }

    func presentStopPaused(for instance: VMInstance) {
        enqueue { $0.present($0.stopPausedConfig(instance)) }
    }

    func presentCancelPreparing(for instance: VMInstance) {
        enqueue { $0.present($0.cancelPreparingConfig(instance)) }
    }

    func presentInstallerMounted(vmName: String) {
        enqueue { $0.present($0.installerMountedConfig(vmName)) }
    }

    // MARK: - Serialization queue

    private func enqueue(_ work: @escaping (DetailAlertsPresenter) -> Void) {
        pending.append(work)
        runNext()
    }

    private func runNext() {
        guard window != nil, !isShowingAlert, !deleteSheetPresenter.isShown, !pending.isEmpty else {
            return
        }
        let next = pending.removeFirst()
        next(self)
    }

    private func present(_ config: AlertConfiguration) {
        guard let window else { return }
        isShowingAlert = true
        presentSheetAlert(config, in: window) { [weak self] in
            self?.isShowingAlert = false
            self?.runNext()
        }
    }

    private func showDeleteSheet(for instance: VMInstance) {
        guard let window else { return }
        let externals = viewModel.externalAttachments(for: instance)
        let content = DeleteVMSheetContentViewController(vmName: instance.name, externals: externals)
        content.delegate = self
        deleteSheetInstance = instance
        deleteSheetPresenter.onClose = { [weak self] in
            self?.deleteSheetInstance = nil
            self?.runNext()
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
        deleteSheetPresenter.close()
    }

    func deleteVMSheet(
        _ vc: DeleteVMSheetContentViewController, didConfirmTrashExternals trashExternals: Bool
    ) {
        if let instance = deleteSheetInstance {
            _ = viewModel.deleteConfirmed(instance, trashExternals: trashExternals)
        }
        deleteSheetPresenter.close()
    }
}
