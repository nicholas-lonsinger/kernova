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
    /// The Take Snapshot sheet's slot, and the VM the shown one names; `nil`
    /// when no sheet is on screen.
    private let snapshotSheetPresenter = SheetPresenter()
    private var shownSnapshotInstance: VMInstance?
    /// Whether a Take Snapshot sheet is waiting in ``pending`` — the half of
    /// the dedupe ``shownSnapshotInstance`` can't answer, since that is only
    /// set once the queue reaches the request.
    private var isSnapshotSheetQueued = false
    /// Keeps the shown Take Snapshot sheet's copy on the kind its VM would
    /// capture *now*, which a guest finishing its shutdown moves while the
    /// sheet is up; cancelled when the sheet closes.
    private var snapshotSheetKindObservation: ObservationLoop?
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
        shownSnapshotInstance = nil
        isSnapshotSheetQueued = false
        snapshotSheetKindObservation?.cancel()
        snapshotSheetKindObservation = nil
        if snapshotSheetPresenter.isShown { snapshotSheetPresenter.reset() }
    }

    #if DEBUG
    /// Number of presentation closures currently queued.
    var pendingCountForTesting: Int { pending.count }

    /// Whether a Take Snapshot sheet request is waiting behind another alert.
    var isSnapshotSheetQueuedForTesting: Bool { isSnapshotSheetQueued }

    /// The revert confirmation's rendered copy, so a test can assert on what it
    /// tells the user is lost.
    func revertSnapshotAlertForTesting(
        _ snapshot: VMSnapshot, for instance: VMInstance
    ) -> AlertConfiguration {
        revertSnapshotConfig(snapshot, instance)
    }

    /// The Force Stop / Discard Saved State confirmation's rendered copy, so a
    /// test can assert on what it tells the user will happen.
    func forceStopAlertForTesting(_ instance: VMInstance) -> AlertConfiguration {
        forceStopConfig(instance)
    }

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

    func presentError(_ message: String, title: String) {
        enqueue { $0.present($0.errorConfig(message, title: title)) }
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

    func presentTakeSnapshotSheet(for instance: VMInstance) {
        // A window-modal sheet is authoritative while it is up: a second
        // gesture (the menu key equivalent stays live under it) is dropped
        // rather than queued behind it. The queued request counts too — it is
        // only unset once the queue drains, so two gestures made while another
        // alert holds the presenter would otherwise both enqueue.
        guard shownSnapshotInstance == nil, !isSnapshotSheetQueued else {
            Self.logger.debug(
                "Take Snapshot sheet already requested; ignoring request for '\(instance.name, privacy: .public)'"
            )
            return
        }
        isSnapshotSheetQueued = true
        enqueue { $0.showTakeSnapshotSheet(for: instance) }
    }

    private func showTakeSnapshotSheet(for instance: VMInstance) {
        isSnapshotSheetQueued = false
        // The request may have queued behind another alert, so re-check the VM
        // is still snapshottable rather than showing a sheet that can't confirm.
        guard let window, viewModel.canTakeSnapshot(instance) else { return }
        let content = TakeSnapshotSheetContentViewController(
            vmName: instance.name, suggestedName: instance.snapshotManifest.defaultNewName,
            kind: instance.snapshotKindForCapture)
        content.delegate = self
        shownSnapshotInstance = instance
        // The capture's kind is decided at confirm time, so the sheet's copy
        // tracks the VM rather than freezing at what it was when it opened.
        snapshotSheetKindObservation?.cancel()
        snapshotSheetKindObservation = observeRecurring(
            track: { [weak instance] in
                _ = instance?.status
                _ = instance?.hasLiveVirtualMachine
            },
            apply: { [weak content, weak instance] in
                guard let content, let instance else { return }
                content.update(kind: instance.snapshotKindForCapture)
            }
        )
        snapshotSheetPresenter.onClose = { [weak self] in
            self?.shownSnapshotInstance = nil
            self?.snapshotSheetKindObservation?.cancel()
            self?.snapshotSheetKindObservation = nil
            self?.runNext()
        }
        snapshotSheetPresenter.show(content: content, in: window)
    }

    func presentRevertSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance) {
        enqueue { $0.present($0.revertSnapshotConfig(snapshot, instance)) }
    }

    func presentDeleteSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance) {
        enqueue { $0.present($0.deleteSnapshotConfig(snapshot, instance)) }
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

    func presentInstallerMounted(
        vmName: String, purpose: GuestAgentInstallerPurpose, delivery: GuestAgentDiskDelivery
    ) {
        enqueue { $0.present($0.installerMountedConfig(vmName, purpose: purpose, delivery: delivery)) }
    }

    // MARK: - Serialization queue

    private func enqueue(_ work: @escaping (DetailAlertsPresenter) -> Void) {
        pending.append(work)
        runNext()
    }

    private func runNext() {
        guard window != nil, !isShowingAlert, !deleteSheetPresenter.isShown,
            !snapshotSheetPresenter.isShown, !pending.isEmpty
        else {
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
            hasSavedState: request.instance.hasSaveFile,
            snapshotCount: request.instance.snapshotManifest.snapshots.count,
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

    /// The revert confirmation.
    ///
    /// The safe path — check-point the current state, then revert — is the
    /// default button, so Return never fires the destructive one. It is offered
    /// wherever a capture can be taken, which covers a stopped VM (a disks-only
    /// check-point); a VM that cannot be captured at all — cold-paused, or
    /// mid-operation — is offered the revert alone.
    private func revertSnapshotConfig(
        _ snapshot: VMSnapshot, _ vm: VMInstance
    ) -> AlertConfiguration {
        var buttons: [AlertButton] = []
        if vm.canTakeSnapshot {
            buttons.append(
                AlertButton("Take Snapshot, Then Revert", role: .default) { [weak self] in
                    guard let self else { return }
                    Task { await self.viewModel.snapshotThenRevertConfirmed(vm, to: snapshot) }
                })
        }
        buttons.append(
            AlertButton("Revert", role: .destructive) { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.revertConfirmed(vm, to: snapshot) }
            })
        buttons.append(AlertButton("Cancel", role: .cancel))

        return AlertConfiguration(
            title:
                "Revert \u{201C}\(vm.name)\u{201D} to \u{201C}\(snapshot.name)\u{201D}?",
            message: Self.revertMessage(snapshot, vm),
            buttons: buttons)
    }

    /// What the revert alert says the user is trading away, by what the target
    /// snapshot holds and what the VM holds now.
    static func revertMessage(_ snapshot: VMSnapshot, _ vm: VMInstance) -> String {
        let taken = SnapshotDateFormat.string(from: snapshot.createdAt)
        let guestLoss =
            vm.canTakeSnapshot
            ? "Everything changed inside the guest since then will be lost unless you take a snapshot first."
            : "Everything changed inside the guest since then will be lost."

        switch snapshot.kind {
        case .warm:
            // A cold-paused VM's own suspend slot is the state it would
            // otherwise resume into, and the revert writes over it.
            let loss =
                vm.isColdPaused
                ? "The suspended session this VM would resume into is replaced by the snapshot\u{2019}s, "
                    + "and everything changed inside the guest since then will be lost."
                : guestLoss
            return "The VM will return to the state and settings captured \(taken). "
                + "\(loss) The snapshot itself is kept."
        case .cold:
            // No memory image to come back on, so whatever session the VM holds
            // now — running or suspended — is gone rather than replaced.
            let session: String
            if vm.hasLiveVirtualMachine {
                session = "The session it is running now ends. "
            } else if vm.isColdPaused {
                session = "The suspended session it would resume into is discarded. "
            } else {
                session = ""
            }
            return "The VM will return to the disks and settings captured \(taken), powered off. "
                + "\(session)\(guestLoss) The snapshot itself is kept."
        }
    }

    private func deleteSnapshotConfig(
        _ snapshot: VMSnapshot, _ vm: VMInstance
    ) -> AlertConfiguration {
        AlertConfiguration(
            title: "Delete \u{201C}\(snapshot.name)\u{201D}?",
            message:
                "Moves this snapshot\u{2019}s saved state and disk copies to the Trash. "
                + "\u{201C}\(vm.name)\u{201D} keeps the state it has now.",
            buttons: [
                AlertButton("Delete", role: .destructive) { [weak self] in
                    self?.viewModel.deleteSnapshotConfirmed(vm, snapshot: snapshot)
                },
                AlertButton("Cancel", role: .cancel),
            ])
    }

    private func forceStopConfig(_ vm: VMInstance) -> AlertConfiguration {
        // A cold-paused ephemeral VM's discard is a revert to its baseline, so
        // the button names that outcome rather than the deletion it isn't.
        let ephemeralBaseline = vm.isColdPaused ? vm.ephemeralBaselineSnapshot : nil
        let discardLabel = ephemeralBaseline == nil ? "Discard" : "Revert to Baseline"
        var buttons: [AlertButton] = [
            AlertButton(vm.isColdPaused ? discardLabel : "Force Stop", role: .destructive) {
                [weak self] in
                guard let self else { return }
                Task { await self.viewModel.forceStopConfirmed(vm) }
            }
        ]
        // Paused VMs route through the dedicated "Stop Paused" alert instead;
        // showing "Shut Down" here would chain a second alert on top of this one.
        if vm.canStop && vm.status != .paused {
            buttons.append(
                AlertButton("Shut Down", role: .default) { [weak self] in
                    guard let self else { return }
                    Task { await self.viewModel.stop(vm) }
                })
        }
        buttons.append(AlertButton("Cancel", role: .cancel))
        let message: String
        if let ephemeralBaseline {
            message =
                "\"\(vm.name)\" is ephemeral, so discarding its suspended session returns it to "
                + "\u{201C}\(ephemeralBaseline.name)\u{201D}. Everything changed inside the guest "
                + "during the session is discarded."
        } else if vm.isColdPaused {
            message =
                "\"\(vm.name)\" has its state saved to disk. Discarding will permanently delete the saved state."
        } else {
            message =
                "\"\(vm.name)\" will be immediately terminated. Any unsaved data inside the guest will be lost."
        }
        return AlertConfiguration(
            title: vm.isColdPaused ? "Discard Saved State" : "Force Stop Virtual Machine",
            message: message,
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

    private func errorConfig(_ message: String, title: String) -> AlertConfiguration {
        AlertConfiguration(
            title: title, message: message, buttons: [AlertButton("OK", role: .cancel)])
    }

    private func startFailedAttachmentConfig(
        _ failure: StartFailedAttachment, _ vm: VMInstance
    ) -> AlertConfiguration {
        var message =
            "\(failure.message)\n\nYou can remove “\(failure.label)” from this virtual machine and start without it. The file itself is not deleted, and you can re-attach it later in Settings."
        if vm.hasSaveFile {
            message +=
                " Removing it also discards this virtual machine’s saved state, which can only be restored with the same devices attached."
        }
        return AlertConfiguration(
            title: "Couldn't Start “\(vm.name)”",
            message: message,
            buttons: [
                AlertButton("Remove and Start", role: .default) { [weak self] in
                    guard let self else { return }
                    Task { await self.viewModel.removeStartFailedAttachmentAndStart(failure, on: vm) }
                },
                AlertButton("Cancel", role: .cancel),
            ])
    }

    private func installerMountedConfig(
        _ vmName: String, purpose: GuestAgentInstallerPurpose, delivery: GuestAgentDiskDelivery
    ) -> AlertConfiguration {
        let nextStep: String
        switch purpose {
        case .install:
            nextStep = "run install.command to complete setup."
        case .manage:
            nextStep =
                "run install.command to reinstall, or uninstall.command to remove the agent."
        }

        let title: String
        let lead: String
        switch delivery {
        case .usb:
            title = purpose == .install ? "Installer Mounted" : "Guest Agent Disk Attached"
            lead = "The Kernova guest agent disk has been attached to \(vmName) as a USB disk."
        case .virtio:
            // Nothing was attached just now — the disk is there for the whole
            // session, so the alert describes where it already is.
            title = "Guest Agent Disk Attached"
            lead = "The Kernova guest agent disk stays attached to \(vmName) whenever it runs."
        }

        return AlertConfiguration(
            title: title,
            message:
                "\(lead) Inside the VM, open the “\(KernovaMacOSAgentInfo.diskLabel)” disk in Finder and \(nextStep)",
            buttons: [AlertButton("OK", role: .cancel)])
    }
}

// MARK: - TakeSnapshotSheetContentViewControllerDelegate

extension DetailAlertsPresenter: TakeSnapshotSheetContentViewControllerDelegate {
    func takeSnapshotSheetDidCancel(_ vc: TakeSnapshotSheetContentViewController) {
        snapshotSheetPresenter.close()
    }

    func takeSnapshotSheet(
        _ vc: TakeSnapshotSheetContentViewController, didConfirmName name: String, notes: String
    ) {
        if let instance = shownSnapshotInstance {
            viewModel.takeSnapshot(instance, name: name, notes: notes)
        }
        snapshotSheetPresenter.close()
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
