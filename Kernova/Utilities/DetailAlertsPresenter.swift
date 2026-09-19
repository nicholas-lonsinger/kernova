import AppKit
import KernovaKit
import KernovaLogging

/// A ``GuestAccountPasswordRequest`` whose answer fires at most once, whichever
/// of the prompt's endings arrives first — a button, a re-ask that never gets
/// back on screen, or the window going away under it.
///
/// The start that raised the request is suspended on a `withCheckedContinuation`
/// until it is answered, and a continuation resumed twice traps while one never
/// resumed strands the start for the rest of the session: both are what this
/// exists to make unrepresentable.
@MainActor
private final class OneShotGuestAccountAnswer {
    /// What the sheet draws. The request's own answer hook stays in here: one
    /// reachable from outside is one a caller could fire a second time, which
    /// is what this exists to make unrepresentable.
    let prompt: GuestAccountPrompt
    private var answer: (@MainActor (GuestAccountPasswordAnswer) -> Void)?

    init(_ request: GuestAccountPasswordRequest) {
        self.prompt = request.prompt
        self.answer = request.answer
    }

    func callAsFunction(_ value: GuestAccountPasswordAnswer) {
        guard let answer else { return }
        self.answer = nil
        answer(value)
    }
}

/// Presents the detail pane's lifecycle confirmation alerts and the delete
/// sheet on behalf of `DetailContainerViewController`.
///
/// The container is always present and owns the window, so these survive while
/// the VM display is showing. One alert/sheet shows at a time; requests that
/// arrive while one is up (or before the window exists) are queued and run in
/// order.
@MainActor
final class DetailAlertsPresenter: NSObject {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "DetailAlertsPresenter")

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
    /// The alert on screen and the buttons it offered, so ``stop()`` can take
    /// the sheet off the window it is attached to and still run exactly one of
    /// its actions; `nil` when no alert is up.
    private var shownAlert: (alert: NSAlert, buttons: [AlertButton])?
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
    /// The guest-account prompt this presenter owes an answer — on screen, or
    /// queued for a re-ask after a refusal; `nil` when none is outstanding.
    ///
    /// Held so ``stop()`` can answer it. Every other request here is one the
    /// user can raise again; this one has a start suspended behind it.
    private var outstandingGuestAccount: OneShotGuestAccountAnswer?

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
        // disappearing window once this is nil — and neither can an alert
        // action below, which is why this comes first: the pairing prompt
        // answers into the coordinator's next request, and that one belongs on
        // the next window or nowhere.
        let host = window
        window = nil
        // The alert on screen is attached to a window that is going away, so
        // it is dismissed as a cancel: its buttons would otherwise stay on a
        // sheet nobody can act on, with `isShowingAlert` left true under them.
        dismissShownAlert(attachedTo: host)
        // The queue just went, and a guest-account prompt waiting in it has a
        // suspended start behind it — one nothing else will ever resume. A
        // prompt that was on screen answered above; the one-shot is what makes
        // both endings exactly one answer.
        outstandingGuestAccount?(.cancelled)
        outstandingGuestAccount = nil
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
    /// The shown alert's sheet handler, so a test can deliver a dismissal the
    /// headless run loop never does — the real one, built by the same call
    /// `beginSheetModal` was given.
    private var shownAlertDismissal: (@MainActor (NSApplication.ModalResponse) -> Void)?

    /// Delivers `response` to the alert on screen exactly as its sheet handler
    /// would, and answers whether there was one.
    @discardableResult
    func dismissShownAlertForTesting(_ response: NSApplication.ModalResponse) -> Bool {
        guard let dismissal = shownAlertDismissal else { return false }
        shownAlertDismissal = nil
        dismissal(response)
        return true
    }

    /// Whether an alert is on screen.
    var isShowingAlertForTesting: Bool { isShowingAlert }

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
            #log(
                Self.logger, .debug,
                "Delete sheet already on screen; ignoring request for '\(instance.name, privacy: .public)'")
            return
        }
        // De-dup to one delete sheet at a time, with the LATEST request winning
        // until the sheet is shown: a follow-up ⌘⌫ → ⌥⌘⌫ upgrades the mode and a
        // different VM retargets, both by updating `pendingDelete`.
        let wasIdle = pendingDelete == nil
        pendingDelete = PendingDelete(instance: instance, permanently: permanently)
        guard wasIdle else {
            #log(
                Self.logger, .debug,
                "Delete sheet already in flight; coalescing repeat request for '\(instance.name, privacy: .public)'")
            return
        }
        startDeleteResolution()
    }

    /// Resolves the in-flight delete's external files off-main *before* showing,
    /// so the synchronous presentation step never blocks the main actor on a
    /// stale mount.
    private func startDeleteResolution() {
        deleteResolutionTask = Task { @MainActor [weak self] in
            await self?.resolveAndEnqueueDelete()
        }
    }

    private func resolveAndEnqueueDelete() async {
        // Loop so a retarget to a different VM *during* the resolve re-resolves
        // the new VM's externals instead of caching stale ones.
        while let request = pendingDelete {
            let externals = await viewModel.externalAttachments(for: request.instance)
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
            #log(
                Self.logger, .debug,
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
        guard let window, viewModel.capabilities.isAvailable(.takeSnapshot, on: instance),
            let mode = instance.snapshotCaptureMode
        else { return }
        let content = TakeSnapshotSheetContentViewController(
            vmName: instance.name, suggestedName: instance.snapshotManifest.defaultNewName,
            mode: mode)
        content.delegate = self
        shownSnapshotInstance = instance
        // The capture's mode is decided at confirm time, so the sheet's copy
        // tracks the VM rather than freezing at what it was when it opened. A
        // VM that leaves every capturable state while the sheet is up keeps its
        // last-rendered copy — the confirm gate refuses either way.
        snapshotSheetKindObservation?.cancel()
        snapshotSheetKindObservation = observeRecurring(
            track: { [weak instance] in
                _ = instance?.status
                _ = instance?.hasLiveVirtualMachine
            },
            apply: { [weak content, weak instance] in
                guard let content, let instance, let mode = instance.snapshotCaptureMode else {
                    return
                }
                content.update(mode: mode)
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
        // Worded now, while the row is still preparing: the copy can settle
        // behind another alert, and confirming then is a real cancel — the core
        // cleans up the settled copy — so the words must not depend on state
        // that has moved on by the time the alert is drawn.
        guard let state = instance.preparingState else {
            #log(
                Self.logger, .fault,
                "Cancel requested for '\(instance.name, privacy: .public)', which is not preparing")
            assertionFailure("Cancel requested for a VM that is not preparing: \(instance.name)")
            return
        }
        let prompt = VMCommandCore.cancelPreparingPrompt(state.operation, on: instance)
        enqueue { $0.present($0.cancelPreparingConfig(prompt, instance)) }
    }

    func presentInstallerMounted(
        vmName: String, purpose: GuestAgentInstallerPurpose, delivery: GuestAgentDiskDelivery
    ) {
        enqueue { $0.present($0.installerMountedConfig(vmName, purpose: purpose, delivery: delivery)) }
    }

    /// Asks which guest a newly assigned USB accessory goes to.
    ///
    /// Answered rather than queued when it cannot be shown right now — no
    /// window, or something else already on screen. Every other request here
    /// waits its turn because the user asked for it; this one nobody asked for,
    /// a drive being plugged in is no reason to put a window up, and the
    /// coordinator holds its next prompt until this one answers, so a request
    /// ``stop()`` drops with the rest of the queue would silence the prompt for
    /// the rest of the session. Held is the right answer anyway: the accessory
    /// stays with the Mac, one menu item from being placed.
    func presentUSBAccessoryPairing(_ request: USBAccessoryPairingRequest) {
        guard let window, !isShowingAlert, !deleteSheetPresenter.isShown,
            !snapshotSheetPresenter.isShown, pending.isEmpty
        else {
            #log(
                Self.logger, .notice,
                "Holding a USB accessory for the host: there is nowhere on screen to ask which virtual machine should take it"
            )
            request.answer(nil)
            return
        }
        show(USBAccessoryPairingAlert.configuration(for: request), in: window)
    }

    /// Asks for the password the account a macOS guest was set up with still
    /// needs.
    ///
    /// Answered rather than queued when it cannot be shown right now — the same
    /// treatment the pairing prompt gets, for a different reason: the start that
    /// raised this is suspended on the answer, so a request waiting in a queue
    /// that ``stop()`` drops would leave that start suspended for the rest of
    /// the session. ``GuestAccountPasswordAnswer/cancelled`` is what an
    /// unaskable prompt answers, because the alternative retracts the account
    /// and only the user may decide that.
    ///
    /// A prompt already on screen is one of those cases, which is also what
    /// keeps a second Start from booting the guest out from under the question
    /// the first one is asking: the menu key equivalents stay live under a
    /// window-modal sheet, and a detached display window is not covered by one
    /// at all.
    func presentGuestAccountPassword(_ request: GuestAccountPasswordRequest) {
        // A second start for a VM already being asked about: the question on
        // screen is the one gating it, so bring that forward rather than
        // letting the click land on nothing. Answering the newcomer leaves the
        // suspended start it came from resumed, and the sheet still owns the
        // one that matters.
        if let outstanding = outstandingGuestAccount,
            outstanding.prompt.vm.id == request.prompt.vm.id, let window
        {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            #log(
                Self.logger, .notice,
                "Already asking for the account password '\(request.prompt.vm.name, privacy: .public)' was set up with; raising that question"
            )
            request.answer(.cancelled)
            return
        }
        guard window != nil, !isShowingAlert, !deleteSheetPresenter.isShown,
            !snapshotSheetPresenter.isShown, pending.isEmpty
        else {
            #log(
                Self.logger, .notice,
                "Nowhere to ask for the account password '\(request.prompt.vm.name, privacy: .public)' was set up with; not starting it"
            )
            request.answer(.cancelled)
            return
        }
        showGuestAccountPassword(
            OneShotGuestAccountAnswer(request), fields: GuestAccountPasswordFields(), refusal: nil)
    }

    /// Puts the prompt up, carrying `refusal` when a previous click was turned
    /// down — same `fields`, so the password the user typed is still in it.
    ///
    /// The re-ask goes back through the queue, where ``stop()`` can drop it, so
    /// the answer travels as a one-shot the teardown can fire instead: a
    /// suspended start that is never answered is never resumed.
    private func showGuestAccountPassword(
        _ answer: OneShotGuestAccountAnswer, fields: GuestAccountPasswordFields,
        refusal: String?
    ) {
        guard let window else {
            answer(.cancelled)
            return
        }
        outstandingGuestAccount = answer
        fields.show(refusal: refusal)
        show(
            GuestAccountPasswordAlert.configuration(
                prompt: answer.prompt, fields: fields,
                answer: { [weak self] value in
                    if self?.outstandingGuestAccount === answer {
                        self?.outstandingGuestAccount = nil
                    }
                    answer(value)
                },
                retry: { [weak self] message in
                    // Through the queue rather than straight back to `show`: the
                    // dismissal that is running this has yet to reach its
                    // `completion`, and the queue is what decides the order the
                    // slot it frees is filled in.
                    self?.enqueue {
                        $0.showGuestAccountPassword(answer, fields: fields, refusal: message)
                    }
                }),
            in: window)
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
        show(config, in: window)
    }

    /// Puts one alert on screen and owns the flag that says so.
    ///
    /// The flag drops on dismissal rather than on completion, so a button
    /// action that raises its own alert — the pairing prompt answering into the
    /// next queued one — is not refused by the slot it is about to free; the
    /// queue then drains in `completion`, into whatever slot the action left.
    private func show(_ config: AlertConfiguration, in window: NSWindow) {
        isShowingAlert = true
        let didDismiss: () -> Void = { [weak self] in
            self?.isShowingAlert = false
            self?.shownAlert = nil
        }
        let completion: () -> Void = { [weak self] in self?.runNext() }
        #if DEBUG
        shownAlertDismissal = makeSheetAlertDismissal(
            buttons: config.buttons, didDismiss: didDismiss, completion: completion)
        #endif
        let alert = presentSheetAlert(
            config, in: window, didDismiss: didDismiss, completion: completion)
        shownAlert = (alert, config.buttons)
    }

    /// Takes the alert on screen off the window that is going away, as if its
    /// cancel button had been clicked.
    ///
    /// Synchronous, for the reason ``SheetPresenter/reset()`` is: the flag
    /// saying an alert is up has to be down before the next ``start(window:)``,
    /// or the queue is wedged on a sheet nobody can see. The action runs here
    /// too, because the sheet is leaving without a click and something is
    /// waiting on the answer it would have carried — a suspended start, or the
    /// accessory coordinator holding its next prompt. `.cancel` names no
    /// button, so the dismissal AppKit delivers afterwards fires none of them a
    /// second time.
    private func dismissShownAlert(attachedTo host: NSWindow?) {
        guard let shown = shownAlert else { return }
        shownAlert = nil
        isShowingAlert = false
        #if DEBUG
        shownAlertDismissal = nil
        #endif
        host?.endSheet(shown.alert.window, returnCode: .cancel)
        shown.buttons.first { $0.role == .cancel }?.action()
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
            prompt: VMCommandCore.deletePrompt(
                request.instance, permanently: request.permanently,
                externals: resolved.externals),
            bundledDisks: request.instance.bundledStorageDisks,
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

    /// An alternative the core offered that this alert has no route for — a
    /// live button that would do nothing, which is a programming error the same
    /// way a missing handler is.
    private static func reportUnhandledAlternative(
        _ alternative: ConfirmationAlternative, on verb: String
    ) {
        #log(
            logger, .fault,
            "No \(verb, privacy: .public) route for alternative '\(alternative.title, privacy: .public)'"
        )
        assertionFailure("No \(verb) route for alternative '\(alternative.title)'")
    }

    /// The cancel confirmation for a create, clone or import, drawn from the
    /// prompt taken when the gesture was made.
    private func cancelPreparingConfig(
        _ prompt: ConfirmationPrompt, _ instance: VMInstance
    ) -> AlertConfiguration {
        AlertConfiguration(
            confirming: prompt,
            confirm: { [weak self] in self?.viewModel.cancelPreparing(instance) })
    }

    /// The revert confirmation.
    ///
    /// Which actions exist, and every word of the copy, come from the refusal
    /// the core raises; this only draws them.
    private func revertSnapshotConfig(
        _ snapshot: VMSnapshot, _ vm: VMInstance
    ) -> AlertConfiguration {
        AlertConfiguration(
            confirming: VMCommandCore.revertPrompt(snapshot, on: vm),
            confirm: { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.revert(vm, to: snapshot) }
            },
            alternative: { [weak self] alternative in
                guard let self else { return }
                guard alternative.takesCheckpoint else {
                    Self.reportUnhandledAlternative(alternative, on: "revert")
                    return
                }
                Task { await self.viewModel.revert(vm, to: snapshot, takingCheckpoint: true) }
            })
    }

    private func deleteSnapshotConfig(
        _ snapshot: VMSnapshot, _ vm: VMInstance
    ) -> AlertConfiguration {
        AlertConfiguration(
            confirming: VMCommandCore.deleteSnapshotPrompt(snapshot, on: vm),
            confirm: { [weak self] in self?.viewModel.deleteSnapshot(vm, snapshot: snapshot) })
    }

    private func forceStopConfig(_ vm: VMInstance) -> AlertConfiguration {
        AlertConfiguration(
            confirming: VMCommandCore.forceStopPrompt(vm),
            confirm: { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.forceStop(vm) }
            },
            alternative: { [weak self] alternative in
                guard let self else { return }
                guard alternative.disposition == .graceful else {
                    Self.reportUnhandledAlternative(alternative, on: "force stop")
                    return
                }
                Task { await self.viewModel.stop(vm) }
            })
    }

    private func recoveryBootConfig(_ vm: VMInstance) -> AlertConfiguration {
        AlertConfiguration(
            title: "Start “\(vm.name)” in Recovery Mode?",
            message:
                "The virtual machine will boot into the macOS Recovery environment for this launch only. Restart normally to return to macOS.",
            buttons: [
                AlertButton("Start in Recovery", role: .default) { [weak self] in
                    guard let self else { return }
                    Task { await self.viewModel.start(vm, bootIntoRecovery: true) }
                },
                AlertButton("Cancel", role: .cancel),
            ])
    }

    private func stopPausedConfig(_ vm: VMInstance) -> AlertConfiguration {
        // RATIONALE: this alert is itself the confirmation, so both buttons
        // call the facade with consent already given rather than routing
        // through `requestForceStop`, which would stack a second alert on top
        // of this one. The message text makes the destructive outcome explicit,
        // so one confirmation is sufficient.
        AlertConfiguration(
            confirming: VMCommandCore.stopPausedPrompt(vm),
            confirm: { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.resumeAndStop(vm) }
            },
            alternative: { [weak self] alternative in
                guard let self else { return }
                guard alternative.disposition == .force else {
                    Self.reportUnhandledAlternative(alternative, on: "stop paused")
                    return
                }
                Task { await self.viewModel.forceStop(vm) }
            })
    }

    private func errorConfig(_ message: String, title: String) -> AlertConfiguration {
        .acknowledgement(title: title, message: message)
    }

    private func startFailedAttachmentConfig(
        _ failure: StartFailedAttachment, _ vm: VMInstance
    ) -> AlertConfiguration {
        // Only an external file can be picked again: no verb attaches an entry
        // at a bundle-internal path, so the re-attach clause is true for
        // external disks and removable media alone.
        let isInternal =
            failure.kind == .storageDisk
            && vm.effectiveStorageDisks.first { $0.id == failure.id }?.isInternal == true
        var message =
            "\(failure.message)\n\nYou can remove “\(failure.label)” from this virtual machine and start without it. The file itself is not deleted"
        message += isInternal ? "." : ", and you can re-attach it later in Settings."
        if vm.hasSaveFile {
            message +=
                " Removing it also discards this virtual machine's saved state, which can only be restored with the same devices attached."
        }
        // The heading names the bring-up that failed; the button names what the
        // recovery does, which is a start either way — a resume's saved state is
        // discarded along with the attachment.
        return AlertConfiguration(
            title: "Couldn't \(failure.verb == .resume ? "Resume" : "Start") “\(vm.name)”",
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

        return .acknowledgement(
            title: title,
            message:
                "\(lead) Inside the VM, open the “\(KernovaMacOSAgentInfo.diskLabel)” disk in Finder and \(nextStep)"
        )
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
            Task { [viewModel] in
                await viewModel.delete(
                    shown.instance, deletingExternalIDs: ids, permanently: shown.permanently)
            }
        }
        deleteSheetPresenter.close()
    }
}
