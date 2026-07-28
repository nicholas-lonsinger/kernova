import AppKit
import os

/// Presents the detail pane's lifecycle confirmation alerts and the delete
/// sheet on behalf of `DetailContainerViewController`.
///
/// The container is always present and owns the window, so these survive while
/// the VM display is showing. One alert/sheet shows at a time; requests that
/// arrive while one is up (or before the window exists) are queued and run in
/// order.
@MainActor
final class DetailAlertsPresenter: NSObject {
    private static let logger = Logger(subsystem: "app.kernova", category: "DetailAlertsPresenter")

    private let viewModel: VMLibraryViewModel
    private weak var window: NSWindow?
    private let deleteSheetPresenter = SheetPresenter()
    private var isShowingAlert = false
    /// A requested VM deletion (target + disposition).
    private struct PendingDelete {
        let instance: VMInstance
        let permanently: Bool
    }
    /// The request the *shown* delete sheet is presenting, read by the sheet
    /// delegate on confirm; `nil` when no sheet is on screen.
    ///
    /// Frozen as a single value at show time so the displayed sheet and the
    /// confirm disposition can never disagree. Distinct from ``pendingDelete``:
    /// a stale-token close clears this but preserves the in-flight
    /// ``pendingDelete``.
    private var shownDelete: PendingDelete?
    /// The latest in-flight delete request — resolving externals off-main, queued
    /// in `pending`, or shown — used to de-dup and to let the latest gesture win.
    ///
    /// A repeat request updates this last-wins, and the show step reads it as the
    /// single source of truth, so the sheet reflects the latest request *up until
    /// it is shown*. Once on screen the displayed sheet is authoritative — a later
    /// gesture can't silently change a visible modal sheet.
    private var pendingDelete: PendingDelete?
    /// Externals resolved off-main for the delete sheet, tagged with the VM they
    /// belong to, and re-resolved if `pendingDelete` retargets to a different VM
    /// before the sheet is shown.
    private var resolvedDelete: (instanceID: UUID, externals: [ExternalAttachment])?
    /// Identifies the currently-shown delete sheet so a stale sheet's late async
    /// `onClose` can't clear state belonging to a newer sheet — even for the
    /// same VM.
    private var deleteSheetToken = 0
    /// Tracks the off-main external-resolution task so `stop()` can cancel it.
    private var deleteResolutionTask: Task<Void, Never>?
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
        pendingDelete = nil
        resolvedDelete = nil
        // Cleared synchronously rather than via the async `onClose`: the
        // `presentDeleteSheet` ignore guard keys on `shownDelete`, so leaving it
        // set until a late completion fires would wrongly ignore deletes for a
        // window after the next `start()`.
        shownDelete = nil
        // Invalidate the in-flight sheet's `onClose` so its late async close can't
        // clear state belonging to a sheet shown after the next `start()`.
        deleteSheetToken += 1
        pending.removeAll()
        // A resolution task that resolves after teardown can't present on the
        // disappearing window once this is nil.
        window = nil
        // Reset, not close: `reset()` drops `isShown` *synchronously* rather than
        // via the async dismissal completion, so a sheet whose parent window is
        // torn down before that completion fires can't leave `isShown` stuck
        // `true` and silently wedge `runNext`.
        if deleteSheetPresenter.isShown { deleteSheetPresenter.reset() }
    }

    #if DEBUG
    /// Number of presentation closures currently queued.
    var pendingCountForTesting: Int { pending.count }

    /// The VM whose delete is in flight, or `nil` if none.
    var pendingDeleteInstanceIDForTesting: UUID? { pendingDelete?.instance.id }

    /// The latest requested disposition for the in-flight delete.
    var pendingDeletePermanentlyForTesting: Bool? { pendingDelete?.permanently }

    /// Per-shown-sheet identity.
    var deleteSheetTokenForTesting: Int { deleteSheetToken }

    /// The tracked off-main resolution task, so tests can `await` its `.value`.
    var deleteResolutionTaskForTesting: Task<Void, Never>? { deleteResolutionTask }

    /// Drives the delete sheet's close handler directly, with no live window to
    /// present a real sheet.
    func handleDeleteSheetClosedForTesting(token: Int) { handleDeleteSheetClosed(token: token) }

    /// Awaited inside `resolveAndEnqueueDelete` right after the externals
    /// resolve, so a test can drive a retarget into that exact gap.
    var afterDeleteResolveForTesting: (@MainActor () async -> Void)?
    #endif

    // MARK: - Imperative presentation

    func presentError(_ message: String, copyableCommand: String?) {
        enqueue { $0.present($0.errorConfig(message, copyableCommand)) }
    }

    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance) {
        enqueue { $0.present($0.startFailedAttachmentConfig(failure, instance)) }
    }

    func presentDeleteSheet(for instance: VMInstance, permanently: Bool = false) {
        // Once a delete sheet is on screen it is an authoritative, window-modal
        // confirmation — ignore further delete gestures (the menu key-equivalents
        // stay live under a window-modal sheet) until it closes. Coalescing them
        // would overwrite `pendingDelete`, which the shown sheet's close then
        // clears without it ever being shown — silently dropping the delete.
        guard shownDelete == nil else {
            Self.logger.debug(
                "Delete sheet already on screen; ignoring request for '\(instance.name, privacy: .public)'")
            return
        }
        // De-dup to one delete sheet at a time, with the LATEST request winning
        // until the sheet is shown: a follow-up ⌘⌫ → ⌥⌘⌫ upgrades the mode and a
        // different VM retargets, both by updating `pendingDelete`.
        let wasIdle = pendingDelete == nil
        pendingDelete = PendingDelete(instance: instance, permanently: permanently)
        guard wasIdle else {
            Self.logger.debug(
                "Delete sheet already in flight; coalescing repeat request for '\(instance.name, privacy: .public)'")
            return
        }
        startDeleteResolution()
    }

    /// Resolves the in-flight delete's external-file existence off-main *before*
    /// showing, so the synchronous presentation step never blocks the main actor
    /// on a stale mount.
    private func startDeleteResolution() {
        deleteResolutionTask = Task { @MainActor [weak self] in
            await self?.resolveAndEnqueueDelete()
        }
    }

    private func resolveAndEnqueueDelete() async {
        // Loop so a retarget to a different VM *during* the resolve re-resolves
        // the new VM's externals instead of caching stale ones.
        while let request = pendingDelete {
            let externals = await viewModel.externalAttachmentsResolvingExistence(for: request.instance)
            #if DEBUG
            await afterDeleteResolveForTesting?()
            #endif
            // `stop()` ran (cancel + clear), or a teardown cleared the request.
            guard !Task.isCancelled, let latest = pendingDelete else { return }
            if latest.instance.id != request.instance.id { continue }  // retargeted → re-resolve
            resolvedDelete = (request.instance.id, externals)
            deleteResolutionTask = nil
            enqueue { $0.showDeleteSheet() }
            return
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

    private func showDeleteSheet() {
        guard let window, let request = pendingDelete else { return }
        // If the request retargeted to a different VM after this show was
        // enqueued (e.g. while queued behind another alert), the cached externals
        // belong to the wrong VM — re-resolve for the new one instead of showing
        // stale data.
        guard let resolved = resolvedDelete, resolved.instanceID == request.instance.id else {
            resolvedDelete = nil
            deleteResolutionTask?.cancel()
            startDeleteResolution()
            return
        }
        deleteSheetToken += 1
        let token = deleteSheetToken
        let content = DeleteVMSheetContentViewController(
            vmName: request.instance.name,
            bundledDisks: viewModel.bundledDisks(for: request.instance),
            externals: resolved.externals,
            mode: request.permanently ? .immediate : .trash
        )
        content.delegate = self
        shownDelete = request
        deleteSheetPresenter.onClose = { [weak self] in
            self?.handleDeleteSheetClosed(token: token)
        }
        deleteSheetPresenter.show(content: content, in: window)
    }

    private func handleDeleteSheetClosed(token: Int) {
        shownDelete = nil
        // Clear the in-flight delete only if THIS is still the current sheet — a
        // stop()/start() cycle bumps `deleteSheetToken`, so a stale sheet's late
        // async close can't clobber the newer delete and reopen the
        // duplicate-sheet path.
        if token == deleteSheetToken {
            pendingDelete = nil
            resolvedDelete = nil
        }
        runNext()
    }

    // MARK: - Alert configurations

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
        // RATIONALE: this alert is itself a confirmation step, so "Force Stop"
        // calls `forceStopFromPaused` directly rather than routing through
        // `confirmForceStop`, which would stack a second alert on top of this
        // one. The message text makes the destructive outcome explicit, so one
        // confirmation is sufficient.
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

    private func errorConfig(_ message: String, _ copyableCommand: String?) -> AlertConfiguration {
        AlertConfiguration(
            title: "Error",
            message: Self.appendingConvertPrompt(to: message, command: copyableCommand),
            buttons: [AlertButton("OK", role: .cancel)],
            accessory: Self.commandAccessory(copyableCommand))
    }

    private func startFailedAttachmentConfig(
        _ failure: StartFailedAttachment, _ vm: VMInstance
    ) -> AlertConfiguration {
        let message =
            "\(failure.message)\n\nYou can remove “\(failure.label)” from this virtual machine and start without it. The file itself is not deleted, and you can re-attach it later in Settings."
        return AlertConfiguration(
            title: "Couldn't Start “\(vm.name)”",
            message: Self.appendingConvertPrompt(
                to: message, command: failure.conversionCommand),
            buttons: [
                AlertButton("Remove and Start", role: .default) { [weak self] in
                    guard let self else { return }
                    Task { await self.viewModel.removeStartFailedAttachmentAndStart(failure, on: vm) }
                },
                AlertButton("Cancel", role: .cancel),
            ],
            accessory: Self.commandAccessory(failure.conversionCommand))
    }

    /// Introduces the command shown in the accessory, or returns `message`
    /// unchanged when there is no command.
    private static func appendingConvertPrompt(to message: String, command: String?) -> String {
        guard command != nil else { return message }
        return "\(message)\n\n\(DiskImageFormatGuidance.convertPrompt)"
    }

    private static func commandAccessory(_ command: String?) -> (@MainActor () -> NSView)? {
        guard let command else { return nil }
        return { CopyableCommandView(command: command) }
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
        if let shown = shownDelete {
            _ = viewModel.deleteConfirmed(
                shown.instance, deletingExternalIDs: ids, permanently: shown.permanently)
        }
        deleteSheetPresenter.close()
    }
}
