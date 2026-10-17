import AppKit
import KernovaKit
import KernovaLogging

/// A ``GuestAccountPasswordRequest`` whose answer fires at most once, whichever
/// of the prompt's endings arrives first — a button, or the window going away
/// under it.
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
    private var answer: (@MainActor (PresenterAnswer<GuestAccountPasswordAnswer>) -> Void)?

    init(_ request: GuestAccountPasswordRequest) {
        self.prompt = request.prompt
        self.answer = request.answer
    }

    func callAsFunction(_ value: PresenterAnswer<GuestAccountPasswordAnswer>) {
        guard let answer else { return }
        self.answer = nil
        answer(value)
    }
}

/// A question a suspended verb waits on whose answer fires at most once — a
/// button, or the window going away under the alert — for the reason
/// ``OneShotGuestAccountAnswer`` exists.
@MainActor
private final class OneShotQuestion<Answer> {
    private var answer: (@MainActor (PresenterAnswer<Answer>) -> Void)?

    init(_ answer: @escaping @MainActor (PresenterAnswer<Answer>) -> Void) {
        self.answer = answer
    }

    func callAsFunction(_ value: PresenterAnswer<Answer>) {
        guard let answer else { return }
        self.answer = nil
        answer(value)
    }
}

/// Shows every alert and sheet the view model raises on the window the user is
/// working in for what it is about, one at a time per window.
///
/// Where an alert goes is decided when it is about to be shown, by
/// ``AlertWindowScene/destination(about:)`` over the windows as they stand
/// then. Each window shows one alert or sheet at a time — a sheet other code
/// attached counts — and takes the alerts routed to it in the order they were
/// raised; an alert waiting on one window never holds up another. An alert no
/// window the user can see qualifies for is held (``held``) until one does:
/// every event that can make one qualify re-runs the routing. One that waited
/// is shown only while what it says is still true.
///
/// A question a suspended verb waits on is never queued: it is asked now, or
/// answered ``PresenterAnswer/unasked`` when its window is taken or there is
/// none.
@MainActor
final class AppAlertPresenter {
    static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppAlertPresenter")

    let viewModel: VMLibraryViewModel
    private let windows: AppWindowRegistry
    /// What each alert says and does.
    private let configurations: AppAlertConfigurations

    /// The alerts waiting with no window to show on.
    let held = HeldAlerts()

    // MARK: - Queue

    /// What a queued alert shows, held as what it is so it can be routed and
    /// re-checked when it comes up rather than when it was raised.
    private enum Request {
        case error(title: String, message: String, subject: AlertSubject)
        case startFailedAttachment(StartFailedAttachment, VMInstance)
        case startFailure(title: String, message: String, VMInstance)
        case startSummary(title: String, undone: [VMGroupActionResult])
        case deleteSheet(DeleteRequest)
        case takeSnapshot(VMInstance, TakeSnapshotPurpose)
        case revertSnapshot(VMSnapshot, VMInstance)
        case deleteSnapshot(VMSnapshot, VMInstance)
        case forceStop(VMInstance)
        case recoveryBoot(VMInstance)
        case stopPaused(VMInstance)
        case cancelPreparing(ConfirmationPrompt, VMArrival)
        case installerMounted(VMInstance, GuestAgentInstallerPurpose, GuestAgentDiskDelivery)
    }

    /// Every request waiting for its window.
    private var queue = AlertQueue<Request, NSWindow>()

    // MARK: - Windows

    /// What a window the presenter has shown on holds.
    private final class WindowSlot {
        weak var window: NSWindow?
        var occupant: Occupant?
        /// The alert this window is still ending: AppKit runs an alert's
        /// handler while its sheet is attached, so for that turn the sheet
        /// holds the window for no one.
        weak var leavingSheet: NSWindow?
    }

    private enum Occupant {
        case alert(ShownAlert)
        case deleteSheet(DeleteRequest)
        case snapshotSheet(SnapshotSheet)

        var alert: ShownAlert? {
            if case .alert(let shown) = self { shown } else { nil }
        }

        var snapshotSheet: SnapshotSheet? {
            if case .snapshotSheet(let sheet) = self { sheet } else { nil }
        }
    }

    /// What closing a window under an alert does with it.
    private enum WindowCloseDisposition {
        /// The alert asks nothing: it goes back to the queue, to be routed
        /// again.
        case requeue(AlertQueue<Request, NSWindow>.Entry)
        /// The alert asks something: it is dismissed as a cancel, so nothing
        /// runs without the user saying yes.
        case cancel
        /// A suspended verb waits on the alert: it is answered unasked, then
        /// dismissed.
        case unask(@MainActor () -> Void)
    }

    /// One alert on screen.
    private final class ShownAlert {
        var alert: NSAlert?
        let buttons: [AlertButton]
        let onWindowClose: WindowCloseDisposition
        /// The guest-account question this alert asks, so a second start of the
        /// same VM finds it.
        let guestAccount: OneShotGuestAccountAnswer?
        /// Shown on the same window once this alert's dismissal finishes, ahead
        /// of anything waiting — the account prompt putting itself back up.
        var followUp: (@MainActor () -> Void)?

        init(
            buttons: [AlertButton], onWindowClose: WindowCloseDisposition,
            guestAccount: OneShotGuestAccountAnswer?
        ) {
            self.buttons = buttons
            self.onWindowClose = onWindowClose
            self.guestAccount = guestAccount
        }
    }

    private var slots: [ObjectIdentifier: WindowSlot] = [:]
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    // MARK: - Sheets

    /// One VM's Take Snapshot sheet while it is on screen, with a sheet
    /// presenter of its own, so sheets for two VMs on two windows stand side
    /// by side.
    @MainActor
    private final class SnapshotSheet {
        let instance: VMInstance
        let presenter = SheetPresenter()
        /// Keeps the sheet's copy on the kind its VM would capture *now*, which
        /// a guest finishing its shutdown moves while the sheet is up;
        /// cancelled when the sheet closes.
        var kindObservation: ObservationLoop?

        init(instance: VMInstance) { self.instance = instance }
    }

    /// One VM's delete, from the gesture to its sheet's close — resolving its
    /// external files off-main, waiting for its window, or shown.
    ///
    /// A repeat gesture for the same VM sets ``permanently`` until the sheet is
    /// shown, and the show reads it then; once on screen the sheet is
    /// authoritative, and a later gesture can't silently change a visible
    /// modal sheet.
    @MainActor
    private final class DeleteRequest {
        let instance: VMInstance
        var permanently: Bool
        /// The VM's external files, once resolved.
        var externals: [ExternalAttachment]?
        /// The off-main resolution of ``externals``.
        var resolution: Task<Void, Never>?
        /// This delete's own sheet, for the reason ``SnapshotSheet`` has one.
        let presenter = SheetPresenter()

        init(instance: VMInstance, permanently: Bool) {
            self.instance = instance
            self.permanently = permanently
        }
    }

    /// Every delete in flight, by its VM's id — one per VM.
    private var deletes: [UUID: DeleteRequest] = [:]

    init(viewModel: VMLibraryViewModel, windows: AppWindowRegistry) {
        self.viewModel = viewModel
        self.windows = windows
        self.configurations = AppAlertConfigurations(viewModel: viewModel)
        observeWindowEvents()
    }

    isolated deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    #if DEBUG
    /// Number of requests waiting for a window.
    var waitingCountForTesting: Int { queue.waiting.count }

    /// Each delete in flight's disposition — `true` to delete immediately — by
    /// its VM's id.
    var deleteDispositionsForTesting: [UUID: Bool] { deletes.mapValues(\.permanently) }

    /// The off-main resolution of the delete in flight for `vmID`, so tests can
    /// `await` its `.value`.
    func deleteResolutionForTesting(of vmID: UUID) -> Task<Void, Never>? {
        deletes[vmID]?.resolution
    }
    #endif

    // MARK: - Events

    /// Re-runs the routing on every event that can let a waiting alert show:
    /// a window shown, made key or main, deminiaturized, or freed of a sheet,
    /// the app unhidden, or the active Space changed — and handles a window
    /// closing, which the registry reports once the window takes no alert.
    private func observeWindowEvents() {
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didEndSheetNotification,
            NSApplication.didUnhideNotification,
        ] {
            observe(name, in: center) { presenter, _ in presenter.pump() }
        }
        observe(
            NSWorkspace.activeSpaceDidChangeNotification, in: NSWorkspace.shared.notificationCenter
        ) { presenter, _ in presenter.pump() }
        windows.onWindowShown = { [weak self] in self?.pump() }
        windows.onWindowWillClose = { [weak self] window in self?.windowWillClose(window) }
    }

    private func observe(
        _ name: Notification.Name, in center: NotificationCenter,
        _ handle: @escaping @MainActor (AppAlertPresenter, NSWindow?) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self, window)
            }
        }
        observers.append((center, token))
    }

    // MARK: - Routing

    /// The windows as they stand now.
    private func currentScene() -> AlertWindowScene<NSWindow> {
        windows.alertScene(keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow)
    }

    /// The VM `request` is about, or `nil` for one about no VM.
    private func vm(of request: Request) -> VMInstance? {
        switch request {
        case .error(_, _, .vm(let instance)): instance
        case .error(_, _, .library), .startSummary, .cancelPreparing: nil
        case .deleteSheet(let delete): delete.instance
        case .startFailedAttachment(_, let instance), .startFailure(_, _, let instance),
            .takeSnapshot(let instance, _), .revertSnapshot(_, let instance),
            .deleteSnapshot(_, let instance), .forceStop(let instance), .recoveryBoot(let instance),
            .stopPaused(let instance), .installerMounted(let instance, _, _):
            instance
        }
    }

    private func destination(of request: Request, in scene: AlertWindowScene<NSWindow>) -> NSWindow? {
        scene.destination(about: vm(of: request)?.id)
    }

    /// Whether the library lists `instance` — the same VM, not one re-read
    /// under its identity.
    private func lists(_ instance: VMInstance) -> Bool {
        viewModel.instances.contains { $0 === instance }
    }

    /// The VMs a launch account names that the library still lists.
    private func listed(_ undone: [VMGroupActionResult]) -> [VMGroupActionResult] {
        undone.filter { result in viewModel.instances.contains { $0.id == result.vm.id } }
    }

    /// `request` with its subject settled as it is raised: an acknowledgement
    /// about a VM the library no longer lists — a delete's report of the files
    /// it kept, raised once the VM is gone — is about no VM. A request that
    /// acts on its VM keeps it, and ``stillHolds(_:)`` drops it.
    private func settled(_ request: Request) -> Request {
        switch request {
        case .error(let title, let message, .vm(let instance)) where !lists(instance),
            .startFailure(let title, let message, let instance) where !lists(instance):
            .error(title: title, message: message, subject: .library)
        default:
            request
        }
    }

    /// Whether what `request` says is still true: its VM is still in the
    /// library, and the state the alert was raised for still holds, read from
    /// the capability model the menus validate with.
    private func stillHolds(_ request: Request) -> Bool {
        let capabilities = viewModel.capabilities
        switch request {
        case .deleteSheet(let delete):
            return deletes[delete.instance.id] === delete && lists(delete.instance)
        case .cancelPreparing(_, let arrival):
            return viewModel.arrivals.contains { $0 === arrival }
        case .startSummary(_, let undone):
            return !listed(undone).isEmpty
        default:
            break
        }
        if let instance = vm(of: request), !lists(instance) { return false }
        switch request {
        case .takeSnapshot(let vm, _):
            return vm.snapshotCaptureMode != nil
        case .revertSnapshot(let snapshot, let vm):
            return vm.snapshotManifest.snapshots.contains { $0.id == snapshot.id }
                && capabilities.isApplicable(.revertToSnapshot, to: vm)
        case .deleteSnapshot(let snapshot, let vm):
            return vm.snapshotManifest.snapshots.contains { $0.id == snapshot.id }
                && capabilities.isApplicable(.deleteSnapshot, to: vm)
        case .forceStop(let vm):
            return capabilities.isApplicable(.forceStop, to: vm)
                || capabilities.isApplicable(.discardSavedState, to: vm)
        case .recoveryBoot(let vm):
            return capabilities.isApplicable(.startInRecovery, to: vm)
        case .stopPaused(let vm):
            return vm.isLivePaused
        case .installerMounted(let vm, _, _):
            return capabilities.isApplicable(.toggleGuestAgentDisk, to: vm)
        case .error, .startFailedAttachment, .startFailure, .startSummary, .deleteSheet,
            .cancelPreparing:
            return true
        }
    }

    /// Releases what a request dropped before it was shown was holding.
    private func discard(_ request: Request) {
        guard case .deleteSheet(let delete) = request else { return }
        end(delete)
    }

    private func heldAlert(for request: Request) -> HeldAlerts.Alert {
        switch request {
        case .startFailedAttachment(_, let instance), .startFailure(_, _, let instance):
            .startReport(vmIDs: [instance.id])
        case .startSummary(_, let undone):
            .startReport(vmIDs: undone.map(\.vm.id))
        default:
            .other(vmID: vm(of: request)?.id)
        }
    }

    private func enqueue(_ request: Request) {
        queue.enqueue(settled(request))
        pump()
    }

    /// Shows every waiting alert whose window is free and first in line for
    /// it, drops every one whose premise lapsed, and publishes what is held.
    ///
    /// The windows are read afresh for each alert taken, so a pump re-entered
    /// from a sheet going up reads the state that sheet left.
    private func pump() {
        while !queue.waiting.isEmpty,
            let (entry, window) = queue.takeNext(
                destination: { [scene = currentScene()] in destination(of: $0, in: scene) },
                isFree: isFree,
                stillHolds: stillHolds,
                drop: { request in
                    discard(request)
                    #log(Self.logger, .notice, "Dropped an alert whose premise lapsed while it waited")
                })
        {
            show(entry, on: window)
        }
        let scene = currentScene()
        held.update(queue.held { destination(of: $0, in: scene) }.map(heldAlert(for:)))
    }

    private func slot(for window: NSWindow) -> WindowSlot {
        let id = ObjectIdentifier(window)
        if let slot = slots[id] { return slot }
        let slot = WindowSlot()
        slot.window = window
        slots[id] = slot
        return slot
    }

    /// Whether nothing holds `window`: no alert or sheet of this presenter's,
    /// and no sheet other code attached.
    private func isFree(_ window: NSWindow) -> Bool {
        let slot = slots[ObjectIdentifier(window)]
        guard slot?.occupant == nil else { return false }
        guard let attached = window.attachedSheet else { return true }
        return attached === slot?.leavingSheet
    }

    /// The window a question about the VM `vmID` names can be asked in now:
    /// its destination, while that is free and no alert raised before it is
    /// waiting for the same window.
    private func askableWindow(about vmID: UUID?) -> NSWindow? {
        let scene = currentScene()
        guard let window = scene.destination(about: vmID), isFree(window),
            !queue.isAwaited(window, destination: { destination(of: $0, in: scene) })
        else { return nil }
        return window
    }

    // MARK: - Showing

    private func show(_ entry: AlertQueue<Request, NSWindow>.Entry, on window: NSWindow) {
        switch entry.request {
        case .error(let title, let message, _), .startFailure(let title, let message, _):
            showAlert(
                .acknowledgement(title: title, message: message), on: window,
                onWindowClose: .requeue(entry))
        case .startFailedAttachment(let failure, let instance):
            showAlert(
                configurations.startFailedAttachmentConfig(failure, instance), on: window,
                onWindowClose: .requeue(entry))
        case .startSummary(let title, let undone):
            showAlert(
                .acknowledgement(title: title, message: listed(undone).undoneMessage(for: .start)),
                on: window, onWindowClose: .requeue(entry))
        case .installerMounted(let instance, let purpose, let delivery):
            showAlert(
                configurations.installerMountedConfig(instance.name, purpose: purpose, delivery: delivery),
                on: window, onWindowClose: .requeue(entry))
        case .deleteSheet(let delete):
            showDeleteSheet(delete, on: window)
        case .takeSnapshot(let instance, let purpose):
            showTakeSnapshotSheet(for: instance, purpose: purpose, on: window)
        case .revertSnapshot(let snapshot, let instance):
            showAlert(configurations.revertSnapshotConfig(snapshot, instance), on: window, onWindowClose: .cancel)
        case .deleteSnapshot(let snapshot, let instance):
            showAlert(configurations.deleteSnapshotConfig(snapshot, instance), on: window, onWindowClose: .cancel)
        case .forceStop(let instance):
            showAlert(configurations.forceStopConfig(instance), on: window, onWindowClose: .cancel)
        case .recoveryBoot(let instance):
            showAlert(configurations.recoveryBootConfig(instance), on: window, onWindowClose: .cancel)
        case .stopPaused(let instance):
            showAlert(configurations.pausedStopConfig(instance), on: window, onWindowClose: .cancel)
        case .cancelPreparing(let prompt, let arrival):
            showAlert(configurations.cancelPreparingConfig(prompt, arrival), on: window, onWindowClose: .cancel)
        }
    }

    /// Puts one alert on `window` and records it as what holds the window.
    ///
    /// The window is released on dismissal rather than on completion, so a
    /// button action that raises its own question — the pairing prompt
    /// answering into the next one — finds the window free; the queue then
    /// drains in `completion`, into whatever the action left free.
    @discardableResult
    private func showAlert(
        _ config: AlertConfiguration, on window: NSWindow,
        onWindowClose: WindowCloseDisposition
    ) -> ShownAlert {
        showAlert(SheetAlert(config), on: window, onWindowClose: onWindowClose)
    }

    /// ``showAlert(_:on:onWindowClose:)`` for an alert drawn with an accessory
    /// view.
    @discardableResult
    private func showAlert(
        _ config: SheetAlert, on window: NSWindow,
        onWindowClose: WindowCloseDisposition,
        guestAccount: OneShotGuestAccountAnswer? = nil
    ) -> ShownAlert {
        let slot = slot(for: window)
        let shown = ShownAlert(
            buttons: config.buttons, onWindowClose: onWindowClose, guestAccount: guestAccount)
        // Held before the sheet goes up, so a routing pass the sheet's own
        // window events start finds the window taken.
        slot.occupant = .alert(shown)
        shown.alert = presentSheetAlert(
            config, in: window,
            didDismiss: { [weak slot] in
                guard let slot, slot.occupant?.alert === shown else { return }
                slot.occupant = nil
                slot.leavingSheet = shown.alert?.window
            },
            completion: { [weak self] in
                if let followUp = shown.followUp {
                    shown.followUp = nil
                    followUp()
                }
                self?.pump()
            })
        return shown
    }

    /// Takes everything off a window that is closing.
    ///
    /// A suspended verb's question is answered unasked and any other
    /// question dismissed as a cancel; an alert that asks nothing goes back to
    /// the queue. Everything waiting is routed again with the window out of
    /// the running.
    private func windowWillClose(_ window: NSWindow) {
        if let slot = slots.removeValue(forKey: ObjectIdentifier(window)), let occupant = slot.occupant {
            slot.occupant = nil
            switch occupant {
            case .alert(let shown):
                takeDown(shown, from: window)
            case .deleteSheet(let delete):
                end(delete)
                delete.presenter.close()
            case .snapshotSheet(let sheet):
                sheet.presenter.close()
            }
        }
        pump()
    }

    /// Takes `shown` off `window`, which is closing, by its disposition.
    ///
    /// The sheet ends as `.cancel`, which names no button, so the handler
    /// AppKit runs afterwards fires none of them a second time.
    private func takeDown(_ shown: ShownAlert, from window: NSWindow) {
        switch shown.onWindowClose {
        case .requeue(let entry):
            queue.requeue(entry)
        case .cancel:
            break
        case .unask(let unask):
            unask()
        }
        if let sheet = shown.alert?.window { window.endSheet(sheet, returnCode: .cancel) }
        if case .requeue = shown.onWindowClose { return }
        shown.buttons.first { $0.role == .cancel }?.action()
    }

    // MARK: - Imperative presentation

    func presentError(_ message: String, title: String, about subject: AlertSubject) {
        enqueue(.error(title: title, message: message, subject: subject))
    }

    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance) {
        enqueue(.startFailedAttachment(failure, instance))
    }

    func presentStartFailure(_ message: String, title: String, for instance: VMInstance) {
        enqueue(.startFailure(title: title, message: message, instance))
    }

    func presentStartSummary(title: String, undone: [VMGroupActionResult]) {
        guard !undone.isEmpty else { return }
        enqueue(.startSummary(title: title, undone: undone))
    }

    func presentDeleteSheet(for instance: VMInstance, permanently: Bool = false) {
        // One delete per VM. Once its sheet is on screen it is an
        // authoritative, window-modal confirmation, so a further gesture for
        // the VM (the menu key equivalents stay live under a window-modal
        // sheet) is ignored; until then the latest gesture's disposition wins —
        // ⌘⌫ then ⌥⌘⌫ upgrades to Delete Immediately.
        if let delete = deletes[instance.id] {
            guard !delete.presenter.isShown else {
                #log(
                    Self.logger, .debug,
                    "Delete sheet already on screen; ignoring request for '\(instance.name, privacy: .public)'")
                return
            }
            delete.permanently = permanently
            #log(
                Self.logger, .debug,
                "Delete sheet already in flight; coalescing repeat request for '\(instance.name, privacy: .public)'")
            return
        }
        let delete = DeleteRequest(instance: instance, permanently: permanently)
        deletes[instance.id] = delete
        // The external files are resolved off-main *before* the sheet is
        // queued, so the synchronous show never blocks the main actor on a
        // stale mount.
        delete.resolution = Task { @MainActor [weak self, viewModel] in
            let externals = await viewModel.externalAttachments(for: instance)
            guard let self, !Task.isCancelled, deletes[instance.id] === delete else { return }
            delete.externals = externals
            delete.resolution = nil
            enqueue(.deleteSheet(delete))
        }
    }

    /// Ends `delete`: cancels its resolution and frees its VM for the next
    /// one. Its sheet, if shown, is closed by the caller.
    private func end(_ delete: DeleteRequest) {
        delete.resolution?.cancel()
        delete.resolution = nil
        if deletes[delete.instance.id] === delete {
            deletes.removeValue(forKey: delete.instance.id)
        }
    }

    func presentTakeSnapshotSheet(for instance: VMInstance, purpose: TakeSnapshotPurpose) {
        // One Take Snapshot sheet per VM, shown or waiting. A window-modal
        // sheet is authoritative while it is up: a second gesture for its VM
        // (the menu key equivalent stays live under it) is dropped rather than
        // queued behind it, and so is one made while the first waits for its
        // window.
        let isWaiting = queue.waiting.contains {
            if case .takeSnapshot(let waiting, _) = $0.request { waiting.id == instance.id } else { false }
        }
        let isShown = slots.values.contains { $0.occupant?.snapshotSheet?.instance.id == instance.id }
        guard !isWaiting, !isShown else {
            #log(
                Self.logger, .debug,
                "Take Snapshot sheet already requested; ignoring request for '\(instance.name, privacy: .public)'"
            )
            return
        }
        enqueue(.takeSnapshot(instance, purpose))
    }

    private func showTakeSnapshotSheet(
        for instance: VMInstance, purpose: TakeSnapshotPurpose, on window: NSWindow
    ) {
        guard let mode = instance.snapshotCaptureMode else { return }
        let sheet = SnapshotSheet(instance: instance)
        let content = TakeSnapshotSheetContentViewController(
            vmName: instance.name, suggestedName: instance.snapshotManifest.defaultNewName,
            mode: mode, purpose: purpose)
        content.onCancel = { [weak sheet] in sheet?.presenter.close() }
        content.onConfirm = { [weak self, weak sheet] name, notes in
            guard let self, let sheet else { return }
            viewModel.takeSnapshot(sheet.instance, name: name, notes: notes, for: purpose)
            sheet.presenter.close()
        }
        // The capture's mode is decided at confirm time, so the sheet's copy
        // tracks the VM rather than freezing at what it was when it opened. A
        // VM that leaves every capturable state while the sheet is up keeps its
        // last-rendered copy — the confirm gate refuses either way.
        sheet.kindObservation = observeRecurring(
            track: { [weak instance] in
                _ = instance?.snapshotCaptureMode
            },
            apply: { [weak content, weak instance] in
                guard let content, let instance, let mode = instance.snapshotCaptureMode else {
                    return
                }
                content.update(mode: mode)
            }
        )
        let slot = slot(for: window)
        sheet.presenter.onClose = { [weak self, weak slot, weak sheet] in
            if let sheet {
                sheet.kindObservation?.cancel()
                if slot?.occupant?.snapshotSheet === sheet { slot?.occupant = nil }
            }
            self?.pump()
        }
        slot.occupant = .snapshotSheet(sheet)
        sheet.presenter.show(content: content, in: window)
    }

    func presentRevertSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance) {
        enqueue(.revertSnapshot(snapshot, instance))
    }

    func presentDeleteSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance) {
        enqueue(.deleteSnapshot(snapshot, instance))
    }

    func presentForceStop(for instance: VMInstance) {
        enqueue(.forceStop(instance))
    }

    func presentRecoveryBoot(for instance: VMInstance) {
        enqueue(.recoveryBoot(instance))
    }

    func presentStopPaused(for instance: VMInstance) {
        enqueue(.stopPaused(instance))
    }

    func presentCancelPreparing(for arrival: VMArrival) {
        // Worded now, from the arrival's kind: the copy can settle behind
        // another alert, so the words must not depend on state that has moved
        // on by the time the alert is drawn.
        enqueue(.cancelPreparing(VMCommandCore.cancelPreparingPrompt(arrival.kind), arrival))
    }

    func presentInstallerMounted(
        for instance: VMInstance, purpose: GuestAgentInstallerPurpose,
        delivery: GuestAgentDiskDelivery
    ) {
        enqueue(.installerMounted(instance, purpose, delivery))
    }

    /// Asks the user to confirm what a verb they started refused without.
    ///
    /// Answered ``PresenterAnswer/unasked`` rather than queued when its window
    /// is taken or there is none: the verb is suspended on the answer, and a
    /// queue waits on a window that may not come back. The verb's refusal then
    /// takes the error path, which does queue. A window closing under it
    /// answers it the same way.
    func presentConfirmationRequest(_ request: ConfirmationRequest) {
        let confirmation = OneShotQuestion(request.answer)
        guard let window = askableWindow(about: request.instance.id) else {
            #log(
                Self.logger, .notice,
                "Nowhere to ask '\(request.prompt.title, privacy: .public)'; leaving its refusal standing")
            confirmation(.unasked)
            return
        }
        showAlert(
            AlertConfiguration(
                confirming: request.prompt, confirm: { confirmation(.answered(true)) },
                dismiss: { confirmation(.answered(false)) }),
            on: window, onWindowClose: .unask { confirmation(.unasked) })
    }

    /// Asks which route through a step refusal to take, answered unasked
    /// rather than queued for the reason ``presentConfirmationRequest(_:)`` is.
    func presentStepRoutes(_ request: StepRouteRequest) {
        let choice = OneShotQuestion(request.answer)
        guard let window = askableWindow(about: request.instance.id) else {
            #log(
                Self.logger, .notice,
                "Nowhere to ask '\(request.requirement.title, privacy: .public)'; leaving its refusal standing")
            choice(.unasked)
            return
        }
        showAlert(
            AlertConfiguration(
                offering: request.requirement, then: request.verbTitle,
                choose: { choice(.answered($0)) }, dismiss: { choice(.answered(nil)) }),
            on: window, onWindowClose: .unask { choice(.unasked) })
    }

    /// Asks which guest a newly assigned USB accessory goes to.
    ///
    /// Answered rather than queued when it cannot be shown right now. Every
    /// other request here waits its turn because the user asked for it; this
    /// one nobody asked for, a drive being plugged in is no reason to put a
    /// window up, and the coordinator holds its next prompt until this one
    /// answers. Held is the right answer anyway: the accessory stays with the
    /// Mac, one menu item from being placed.
    func presentUSBAccessoryPairing(_ request: USBAccessoryPairingRequest) {
        guard let window = askableWindow(about: nil) else {
            #log(
                Self.logger, .notice,
                "Holding a USB accessory for the host: there is nowhere on screen to ask which virtual machine should take it"
            )
            request.answer(nil)
            return
        }
        showAlert(
            USBAccessoryPairingAlert.configuration(for: request), on: window, onWindowClose: .cancel)
    }

    /// Asks for the password the account a macOS guest was set up with still
    /// needs.
    ///
    /// Answered ``PresenterAnswer/unasked`` rather than queued when it cannot
    /// be shown right now, for the reason ``presentConfirmationRequest(_:)``
    /// is.
    ///
    /// A prompt already on screen for the same VM is one of those cases, which
    /// is also what keeps a second Start from booting the guest out from under
    /// the question the first one is asking: the menu key equivalents stay live
    /// under a window-modal sheet, and another window is not covered by one at
    /// all.
    func presentGuestAccountPassword(_ request: GuestAccountPasswordRequest) {
        let vmID = request.prompt.vm.id
        // A second start for a VM already being asked about: the question on
        // screen is the one gating it, so bring that forward rather than
        // letting the click land on nothing. Answering the newcomer leaves the
        // suspended start it came from resumed, and the sheet still owns the
        // one that matters.
        if let asking = windowAsking(about: vmID) {
            asking.makeKeyAndOrderFront(nil)
            windows.presence.activate()
            #log(
                Self.logger, .notice,
                "Already asking for the account password '\(request.prompt.vm.name, privacy: .public)' was set up with; raising that question"
            )
            request.answer(.answered(.cancelled))
            return
        }
        guard let window = askableWindow(about: vmID) else {
            #log(
                Self.logger, .notice,
                "Nowhere to ask for the account password '\(request.prompt.vm.name, privacy: .public)' was set up with; leaving its refusal standing"
            )
            request.answer(.unasked)
            return
        }
        showGuestAccountPassword(
            OneShotGuestAccountAnswer(request), fields: GuestAccountPasswordFields(), refusal: nil,
            on: window)
    }

    /// The window a guest-account question about the VM `vmID` is on.
    private func windowAsking(about vmID: UUID) -> NSWindow? {
        slots.values.first { $0.occupant?.alert?.guestAccount?.prompt.vm.id == vmID }?.window
    }

    /// Puts the prompt up on `window`, carrying `refusal` when a previous
    /// click was turned down — same `fields`, so the password the user typed is
    /// still in it.
    ///
    /// A refusal puts the prompt back up on the same window once the
    /// dismissal running it has finished, ahead of anything waiting for that
    /// window.
    private func showGuestAccountPassword(
        _ answer: OneShotGuestAccountAnswer, fields: GuestAccountPasswordFields,
        refusal: String?, on window: NSWindow
    ) {
        fields.show(refusal: refusal)
        final class ShownBox { weak var shown: ShownAlert? }
        let box = ShownBox()
        box.shown = showAlert(
            GuestAccountPasswordAlert.configuration(
                prompt: answer.prompt, fields: fields, host: viewModel.library.virtualizationHost,
                answer: { value in answer(.answered(value)) },
                retry: { [weak self, weak window] message in
                    box.shown?.followUp = {
                        guard let self, let window else {
                            answer(.unasked)
                            return
                        }
                        self.showGuestAccountPassword(
                            answer, fields: fields, refusal: message, on: window)
                    }
                }),
            on: window, onWindowClose: .unask { answer(.unasked) }, guestAccount: answer)
    }

    // MARK: - Delete sheet

    private func showDeleteSheet(_ delete: DeleteRequest, on window: NSWindow) {
        guard let externals = delete.externals else { return }
        // Frozen here, so the displayed sheet and the confirmed disposition
        // can never disagree.
        let permanently = delete.permanently
        let instance = delete.instance
        let content = DeleteVMSheetContentViewController(
            prompt: VMCommandCore.deletePrompt(
                instance, permanently: permanently, externals: externals),
            bundledDisks: instance.bundledStorageDisks,
            externals: externals,
            hasSavedState: instance.hasSaveFile,
            snapshotCount: instance.snapshotManifest.snapshots.count,
            mode: permanently ? .immediate : .trash
        )
        content.onCancel = { [weak delete] in delete?.presenter.close() }
        content.onConfirm = { [weak delete, viewModel] ids in
            guard let delete else { return }
            Task {
                await viewModel.delete(instance, deletingExternalIDs: ids, permanently: permanently)
            }
            delete.presenter.close()
        }
        let slot = slot(for: window)
        delete.presenter.onClose = { [weak self, weak slot, weak delete] in
            if let delete {
                if case .deleteSheet(let shown)? = slot?.occupant, shown === delete { slot?.occupant = nil }
                self?.end(delete)
            }
            self?.pump()
        }
        slot.occupant = .deleteSheet(delete)
        delete.presenter.show(content: content, in: window)
    }
}

extension AppAlertPresenter: VMLibraryPresenting {}
