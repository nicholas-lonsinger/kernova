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
    /// The VM the *shown* delete sheet is presenting for, read by the sheet
    /// delegate on confirm.
    ///
    /// Frozen at show time so the displayed sheet and the confirm disposition
    /// always agree.
    private var deleteSheetInstance: VMInstance?
    /// Whether the *shown* delete sheet is the immediate (bypass-Trash) variant.
    ///
    /// The sheet doesn't re-encode the disposition on confirm, so the presenter
    /// remembers which mode it showed and routes accordingly. Frozen at show time
    /// alongside ``deleteSheetInstance``.
    private var deleteSheetPermanent = false

    /// A requested VM deletion (target + disposition).
    private struct PendingDelete {
        let instance: VMInstance
        let permanently: Bool
    }
    /// The latest in-flight delete request — resolving externals off-main, queued
    /// in `pending`, or shown — used to de-dup and to let the latest gesture win.
    ///
    /// A repeat request updates this last-wins (a follow-up ⌥⌘⌫ upgrades the mode;
    /// a different VM retargets); the show step reads it as the single source of
    /// truth, so the sheet always reflects the latest request *up until it is
    /// shown*. Once on screen the displayed sheet is authoritative — a later
    /// gesture can't silently change a visible modal sheet. Cleared by the shown
    /// sheet's close (matched by ``deleteSheetToken``) or on teardown (`stop()`).
    private var pendingDelete: PendingDelete?
    /// Externals resolved off-main for the delete sheet, tagged with the VM they
    /// belong to.
    ///
    /// Re-resolved if `pendingDelete` retargets to a different VM before the
    /// sheet is shown.
    private var resolvedDelete: (instanceID: UUID, externals: [ExternalAttachment])?
    /// Identifies the currently-shown delete sheet so a stale sheet's late async
    /// `onClose` can't clear state belonging to a newer sheet — even for the
    /// same VM.
    ///
    /// Bumped on each show and in `stop()`.
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
        // Clear the shown-sheet state synchronously rather than waiting for the
        // async `onClose` that `close()` (below) schedules: the `presentDeleteSheet`
        // ignore guard keys on `deleteSheetInstance`, so leaving it set until the
        // late completion fires would wrongly ignore deletes for a window after the
        // next `start()`. The late `onClose` clears these again harmlessly.
        deleteSheetInstance = nil
        deleteSheetPermanent = false
        // Invalidate the in-flight sheet's `onClose` so its late async close
        // (fired by the `close()` below) can't clear state belonging to a sheet
        // shown after the next `start()`. stop() has already cleared the
        // in-flight delete itself.
        deleteSheetToken += 1
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

    /// The VM whose delete is in flight, or `nil` if none.
    ///
    /// The show step reads this as the source of truth, so it is what the sheet
    /// would present.
    var pendingDeleteInstanceIDForTesting: UUID? { pendingDelete?.instance.id }

    /// The latest requested disposition for the in-flight delete (last gesture
    /// wins), so a test can assert ⌘⌫-then-⌥⌘⌫ upgrades the sheet to Immediate.
    var pendingDeletePermanentlyForTesting: Bool? { pendingDelete?.permanently }

    /// Per-shown-sheet identity; a test can assert `stop()` bumps it (which
    /// invalidates a stale sheet's late `onClose`).
    var deleteSheetTokenForTesting: Int { deleteSheetToken }

    /// The tracked off-main resolution task, so tests can `await` its `.value`.
    var deleteResolutionTaskForTesting: Task<Void, Never>? { deleteResolutionTask }

    /// Drives the delete sheet's close handler directly so a test can verify the
    /// token guard (a current-token close clears the in-flight delete; a stale
    /// one does not) without a live window to present a real sheet.
    func handleDeleteSheetClosedForTesting(token: Int) { handleDeleteSheetClosed(token: token) }

    /// Test seam: awaited inside `resolveAndEnqueueDelete` right after the
    /// externals resolve, so a test can drive a retarget into that exact gap and
    /// exercise the across-the-await re-resolve (`continue`) path deterministically.
    var afterDeleteResolveForTesting: (@MainActor () async -> Void)?
    #endif

    // MARK: - Imperative presentation

    func presentError(_ message: String) {
        enqueue { $0.present($0.errorConfig(message)) }
    }

    func presentDeleteSheet(for instance: VMInstance, permanently: Bool = false) {
        // Once a delete sheet is on screen it is an authoritative, window-modal
        // confirmation — ignore further delete gestures (the menu key-equivalents
        // stay live under a window-modal sheet) until it closes. Coalescing them
        // would be worse than ignoring: the new request would overwrite
        // `pendingDelete`, then be cleared by the shown sheet's close without ever
        // being shown — silently dropping the delete. `deleteSheetInstance` is set
        // for the whole shown→closing window, so this also covers the gap between
        // a Cancel/Confirm and the sheet's async `onClose`.
        guard deleteSheetInstance == nil else {
            Self.logger.debug(
                "Delete sheet already on screen; ignoring request for '\(instance.name, privacy: .public)'")
            return
        }
        // De-dup to one delete sheet at a time, with the LATEST request winning
        // until the sheet is shown: a follow-up ⌘⌫ → ⌥⌘⌫ upgrades the mode and a
        // different VM retargets, both by updating `pendingDelete` (the single
        // source of truth the show step reads). So a fast double-invoke never
        // opens a second sheet, and the user's most recent intent is honored
        // rather than silently downgraded.
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
    ///
    /// Tracked so `stop()` can cancel it.
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
        // stale data. Cancel any in-flight resolve and start a fresh one so the
        // retarget can never be swallowed (today the task is already nil here).
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
        // Freeze the shown sheet's VM + disposition so the displayed sheet and
        // the confirm delegate always agree, even if a later gesture updates
        // `pendingDelete` while the sheet is up.
        deleteSheetInstance = request.instance
        deleteSheetPermanent = request.permanently
        deleteSheetPresenter.onClose = { [weak self] in
            self?.handleDeleteSheetClosed(token: token)
        }
        deleteSheetPresenter.show(content: content, in: window)
    }

    private func handleDeleteSheetClosed(token: Int) {
        deleteSheetInstance = nil
        deleteSheetPermanent = false
        // Allow the next delete: the sheet has closed (cancel, confirm, or
        // programmatic `close()` all route through here). Clear the in-flight
        // delete only if THIS is still the current sheet — a stop()/start() cycle
        // bumps `deleteSheetToken`, so a stale sheet's late async close (after
        // teardown re-showed a newer sheet, even for the same VM) can't clobber
        // the newer delete and reopen the duplicate-sheet path (#362).
        if token == deleteSheetToken {
            pendingDelete = nil
            resolvedDelete = nil
        }
        runNext()
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
