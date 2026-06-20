import AppKit
import os

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
    private static let logger = Logger(subsystem: "app.kernova", category: "DetailAlertsPresenter")

    private let viewModel: VMLibraryViewModel
    private weak var window: NSWindow?
    private let deleteSheetPresenter = SheetPresenter()
    private var isShowingAlert = false
    /// The VM the delete sheet is currently presenting for, read by the sheet
    /// delegate on confirm.
    private var deleteSheetInstance: VMInstance?
    /// The VM whose delete sheet is in flight — resolving externals off-main,
    /// queued in `pending`, or shown — used to de-dup repeat delete requests.
    ///
    /// Cleared when the sheet closes (`onClose`) or the presenter is torn down
    /// (`stop()`).
    private var pendingDeleteInstanceID: UUID?
    /// Tracks the off-main external-resolution task so `stop()` can cancel it.
    private var deleteResolutionTask: Task<Void, Never>?
    /// Whether the in-flight delete sheet is the immediate (bypass-Trash)
    /// variant.
    ///
    /// The sheet doesn't re-encode the disposition on confirm, so the presenter
    /// remembers which mode it showed and routes accordingly.
    private var deleteSheetPermanent = false
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
        deleteResolutionTask?.cancel()
        deleteResolutionTask = nil
        pendingDeleteInstanceID = nil
        pending.removeAll()
        // Belt-and-suspenders: a resolution task that resolves after teardown
        // (or any late enqueue) can't present on the disappearing window once
        // it's nil. `start(window:)` re-sets it on the next `viewDidAppear`.
        window = nil
        // Order: clear `pending` and nil `window` *before* closing the sheet.
        // `close()` fires `onClose` via the `beginSheet` completion (which calls
        // `runNext()`), and with `window == nil` that `runNext` is a no-op.
        if deleteSheetPresenter.isShown { deleteSheetPresenter.close() }
    }

    #if DEBUG
    /// Number of presentation closures currently queued.
    ///
    /// With no window set (test harness never calls `start`), `runNext` always
    /// bails, so enqueued delete sheets accumulate here for the de-dup tests.
    var pendingCountForTesting: Int { pending.count }

    /// The VM id whose delete sheet is in flight, or `nil` if none.
    var pendingDeleteInstanceIDForTesting: UUID? { pendingDeleteInstanceID }

    /// The tracked off-main resolution task, so tests can `await` its `.value`.
    var deleteResolutionTaskForTesting: Task<Void, Never>? { deleteResolutionTask }
    #endif

    // MARK: - Imperative presentation

    func presentError(_ message: String) {
        enqueue { $0.present($0.errorConfig(message)) }
    }

    func presentDeleteSheet(for instance: VMInstance, permanently: Bool = false) {
        // De-dup: at most one delete sheet is ever in flight. A second request —
        // e.g. ⌘⌫ then ⌥⌘⌫ on the same VM — is ignored so the user never sees a
        // duplicate sheet. Once shown the sheet is window-modal, and while queued
        // a prior alert/sheet blocks the window, so the only reachable re-entry
        // is a fast double-invoke during the brief off-main resolve; that targets
        // the same VM. Different-VM re-entry isn't reachable, so a blanket
        // "already in flight" guard is correct and keeps the single-task invariant.
        guard pendingDeleteInstanceID == nil else {
            Self.logger.debug(
                "Ignoring delete request for '\(instance.name, privacy: .public)'; a delete sheet is already in flight")
            return
        }
        pendingDeleteInstanceID = instance.id
        // Resolve external-file existence off-main *before* enqueuing, so the
        // serialized presentation step stays synchronous and a stale mount
        // can't block the main actor. The brief async gap is acceptable for a
        // user-initiated confirmation sheet. The task is tracked so `stop()` can
        // cancel it.
        deleteResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let externals = await self.viewModel.externalAttachmentsResolvingExistence(for: instance)
            // `stop()` ran during the resolve: bail without enqueuing or touching
            // `pendingDeleteInstanceID` (owned by `onClose`/`stop()`, never cleared
            // here — avoids an ABA race where a stale task clears a newer request).
            guard !Task.isCancelled else { return }
            self.deleteResolutionTask = nil
            self.enqueue { $0.showDeleteSheet(for: instance, externals: externals, permanently: permanently) }
        }
    }

    func presentForceStop(for instance: VMInstance) {
        enqueue { $0.present($0.forceStopConfig(instance)) }
    }

    func presentRecoveryBoot(for instance: VMInstance) {
        enqueue { $0.present($0.recoveryBootConfig(instance)) }
    }

    func presentStopPaused(for instance: VMInstance) {
        enqueue { $0.present($0.stopPausedConfig(instance)) }
    }

    func presentCancelPreparing(for instance: VMInstance) {
        enqueue { $0.present($0.cancelPreparingConfig(instance)) }
    }

    func presentInstallerMounted(vmName: String, purpose: GuestAgentInstallerPurpose) {
        enqueue { $0.present($0.installerMountedConfig(vmName, purpose: purpose)) }
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

    private func showDeleteSheet(
        for instance: VMInstance, externals: [ExternalAttachment], permanently: Bool
    ) {
        guard let window else { return }
        let content = DeleteVMSheetContentViewController(
            vmName: instance.name,
            bundledDisks: viewModel.bundledDisks(for: instance),
            externals: externals,
            mode: permanently ? .immediate : .trash
        )
        content.delegate = self
        deleteSheetInstance = instance
        deleteSheetPermanent = permanently
        deleteSheetPresenter.onClose = { [weak self] in
            self?.deleteSheetInstance = nil
            self?.deleteSheetPermanent = false
            // Allow the next delete: the in-flight sheet has closed (cancel,
            // confirm, or programmatic `close()` all route through here).
            self?.pendingDeleteInstanceID = nil
            self?.runNext()
        }
        deleteSheetPresenter.show(content: content, in: window)
    }

    // MARK: - Alert configurations (copied from the former SwiftUI modifiers)

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

    private func recoveryBootConfig(_ vm: VMInstance) -> AlertConfiguration {
        AlertConfiguration(
            title: "Start “\(vm.name)” in Recovery Mode?",
            message:
                "The virtual machine will boot into the macOS Recovery environment for this launch only. Restart normally to return to macOS.",
            buttons: [
                AlertButton("Start in Recovery", role: .default) { [weak self] in
                    guard let self else { return }
                    Task { await self.viewModel.startInRecoveryConfirmed(vm) }
                },
                AlertButton("Cancel", role: .cancel),
            ])
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

    private func installerMountedConfig(
        _ vmName: String, purpose: GuestAgentInstallerPurpose
    ) -> AlertConfiguration {
        let title: String
        let nextStep: String
        switch purpose {
        case .install:
            title = "Installer Mounted"
            nextStep = "run install.command to complete setup."
        case .manage:
            title = "Guest Agent Disk Attached"
            nextStep =
                "run install.command to reinstall, or uninstall.command to remove the agent."
        }
        return AlertConfiguration(
            title: title,
            message:
                "The Kernova guest agent disk has been attached to \(vmName) as a USB disk. Inside the VM, open the “Kernova Guest Agent” disk in Finder and \(nextStep)",
            buttons: [AlertButton("OK", role: .cancel)])
    }
}

// MARK: - DeleteVMSheetContentViewControllerDelegate

extension DetailAlertsPresenter: DeleteVMSheetContentViewControllerDelegate {
    func deleteVMSheetDidCancel(_ vc: DeleteVMSheetContentViewController) {
        deleteSheetPresenter.close()
    }

    func deleteVMSheet(
        _ vc: DeleteVMSheetContentViewController, didConfirmDeletingExternalIDs ids: Set<UUID>
    ) {
        if let instance = deleteSheetInstance {
            _ = viewModel.deleteConfirmed(
                instance, deletingExternalIDs: ids, permanently: deleteSheetPermanent)
        }
        deleteSheetPresenter.close()
    }
}
