import AppKit
import os

/// Drives the lifecycle confirmation alerts (delete, cancel preparing,
/// force stop, stop paused) from a pure-AppKit detail pane.
///
/// Observes the view model's per-alert booleans. On `false → true`
/// transitions, builds the right alert via ``AlertPresenter`` and dispatches
/// the chosen button index back through the view model. Replaces the SwiftUI
/// `LifecycleAlerts` view modifier previously declared in `VMDetailView`.
@MainActor
final class LifecycleAlertCoordinator {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "LifecycleAlertCoordinator")

    private let viewModel: VMLibraryViewModel
    private weak var window: NSWindow?

    private var deleteAlertObserver: ObservationLoop?
    private var deleteSheetObserver: ObservationLoop?
    private var cancelPreparingObserver: ObservationLoop?
    private var forceStopObserver: ObservationLoop?
    private var stopPausedObserver: ObservationLoop?

    /// Tracks the currently-presented delete sheet so duplicate rising-edge
    /// fires (e.g. the user re-clicks Delete during a sheet teardown) don't
    /// stack a second window.
    private weak var activeDeleteSheet: NSWindowController?

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
    }

    /// Start observing once the host VC has a window.
    func startObserving(in window: NSWindow) {
        self.window = window
        deleteAlertObserver = observeModalFlag(
            { [weak viewModel] in viewModel?.showDeleteConfirmation ?? false },
            present: { [weak self] in self?.presentDeleteAlert() }
        )
        deleteSheetObserver = observeModalFlag(
            { [weak viewModel] in viewModel?.showDeleteSheet ?? false },
            present: { [weak self] in self?.presentDeleteSheet() }
        )
        cancelPreparingObserver = observeModalFlag(
            { [weak viewModel] in viewModel?.showCancelPreparingConfirmation ?? false },
            present: { [weak self] in self?.presentCancelPreparing() }
        )
        forceStopObserver = observeModalFlag(
            { [weak viewModel] in viewModel?.showForceStopConfirmation ?? false },
            present: { [weak self] in self?.presentForceStop() }
        )
        stopPausedObserver = observeModalFlag(
            { [weak viewModel] in viewModel?.showStopPausedConfirmation ?? false },
            present: { [weak self] in self?.presentStopPaused() }
        )
    }

    func stopObserving() {
        deleteAlertObserver?.cancel(); deleteAlertObserver = nil
        deleteSheetObserver?.cancel(); deleteSheetObserver = nil
        cancelPreparingObserver?.cancel(); cancelPreparingObserver = nil
        forceStopObserver?.cancel(); forceStopObserver = nil
        stopPausedObserver?.cancel(); stopPausedObserver = nil
    }

    // MARK: - Delete

    private func presentDeleteAlert() {
        guard let window, let instance = viewModel.instanceToDelete else {
            viewModel.showDeleteConfirmation = false
            return
        }
        let name = instance.name
        AlertPresenter.present(
            in: window,
            title: "Delete Virtual Machine",
            message:
                "\u{201C}\(name)\u{201D} will be moved to the Trash. "
                + "You can restore it using Finder's Put Back command. "
                + "Empty the Trash to permanently delete the VM and reclaim disk space.",
            style: .warning,
            buttons: [.destructive("Move to Trash"), .cancel()]
        ) { [weak self] index in
            guard let self else { return }
            self.viewModel.showDeleteConfirmation = false
            if index == 0 {
                self.viewModel.deleteConfirmed(instance)
            } else {
                self.viewModel.instanceToDelete = nil
            }
        }
    }

    private func presentDeleteSheet() {
        guard let window, let instance = viewModel.instanceToDelete else {
            viewModel.showDeleteSheet = false
            return
        }
        if activeDeleteSheet != nil {
            Self.logger.debug("Delete sheet already active — ignoring duplicate request")
            return
        }
        let externals = viewModel.externalAttachments(for: instance)
        let sheet = DeleteVMSheetWindowController(
            instance: instance,
            externals: externals,
            initialTrashExternals: viewModel.trashExternalsOnDelete,
            onCancel: { [weak self] in
                self?.viewModel.showDeleteSheet = false
                self?.viewModel.instanceToDelete = nil
                self?.viewModel.trashExternalsOnDelete = false
            },
            onConfirm: { [weak self] trashExternals in
                guard let self else { return }
                self.viewModel.trashExternalsOnDelete = trashExternals
                self.viewModel.showDeleteSheet = false
                self.viewModel.deleteConfirmed(instance, trashExternals: trashExternals)
            }
        )
        activeDeleteSheet = sheet
        Task { [weak self] in
            await sheet.runSheet(on: window)
            self?.activeDeleteSheet = nil
        }
    }

    // MARK: - Cancel preparing

    private func presentCancelPreparing() {
        guard let window, let instance = viewModel.preparingInstanceToCancel else {
            viewModel.showCancelPreparingConfirmation = false
            return
        }
        let title = instance.preparingState?.operation.cancelAlertTitle ?? "Cancel Operation"
        let cancelLabel = instance.preparingState?.operation.cancelLabel ?? "Cancel Operation"
        AlertPresenter.present(
            in: window,
            title: title,
            message:
                "The operation will be stopped and any partially copied files will be removed.",
            style: .warning,
            buttons: [.destructive(cancelLabel), AlertButton(title: "Continue", role: .cancel)]
        ) { [weak self] index in
            guard let self else { return }
            self.viewModel.showCancelPreparingConfirmation = false
            if index == 0 {
                self.viewModel.cancelPreparingConfirmed(instance)
            } else {
                self.viewModel.preparingInstanceToCancel = nil
            }
        }
    }

    // MARK: - Force stop

    private func presentForceStop() {
        guard let window, let instance = viewModel.instanceToForceStop else {
            viewModel.showForceStopConfirmation = false
            return
        }
        let title = instance.isColdPaused ? "Discard Saved State" : "Force Stop Virtual Machine"
        let primaryLabel = instance.isColdPaused ? "Discard" : "Force Stop"
        let message: String =
            instance.isColdPaused
            ? "\u{201C}\(instance.name)\u{201D} has its state saved to disk. Discarding will permanently delete the saved state."
            : "\u{201C}\(instance.name)\u{201D} will be immediately terminated. Any unsaved data inside the guest will be lost."

        // The middle "Shut Down" button only appears on running VMs that
        // aren't paused; paused VMs route through the dedicated Stop Paused
        // alert.
        let showShutDown = instance.canStop && instance.status != .paused
        var buttons: [AlertButton] = [.destructive(primaryLabel)]
        if showShutDown {
            buttons.append(.plain("Shut Down"))
        }
        buttons.append(.cancel())

        AlertPresenter.present(
            in: window,
            title: title,
            message: message,
            style: .warning,
            buttons: buttons
        ) { [weak self] index in
            guard let self else { return }
            self.viewModel.showForceStopConfirmation = false
            switch index {
            case 0:
                Task { @MainActor in await self.viewModel.forceStopConfirmed(instance) }
            case 1 where showShutDown:
                self.viewModel.stop(instance)
                self.viewModel.instanceToForceStop = nil
            default:
                self.viewModel.instanceToForceStop = nil
            }
        }
    }

    // MARK: - Stop paused

    private func presentStopPaused() {
        guard let window, let instance = viewModel.instanceToStopPaused else {
            viewModel.showStopPausedConfirmation = false
            return
        }
        AlertPresenter.present(
            in: window,
            title: "Stop Paused Virtual Machine",
            message:
                "\u{201C}\(instance.name)\u{201D} is paused and cannot be shut down directly. "
                + "Resume it to send a graceful shutdown, or force stop to terminate it immediately "
                + "(any unsaved data inside the guest will be lost).",
            style: .warning,
            buttons: [
                .default("Resume and Shut Down"),
                .destructive("Force Stop"),
                .cancel(),
            ]
        ) { [weak self] index in
            guard let self else { return }
            self.viewModel.showStopPausedConfirmation = false
            switch index {
            case 0:
                Task { @MainActor in await self.viewModel.resumeAndStop(instance) }
            case 1:
                Task { @MainActor in await self.viewModel.forceStopFromPaused(instance) }
            default:
                self.viewModel.instanceToStopPaused = nil
            }
        }
    }
}
