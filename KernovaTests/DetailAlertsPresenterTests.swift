import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers the delete-sheet de-dup state machine (issue #362 and follow-ups
/// #364/#366): one sheet in flight at a time, the latest gesture winning (mode
/// upgrade *and* different-VM retarget) up until the sheet is shown, a
/// cancellable off-main resolution, and a per-sheet token so a stale close can't
/// clobber a newer delete.
///
/// Most tests don't call `start(window:)`, so `window == nil` and `runNext()`
/// always bails — enqueued show closures simply accumulate in `pending` (the
/// in-flight request is observed via the `…ForTesting` seams, and the
/// close-handler's token guard is driven directly through
/// `handleDeleteSheetClosedForTesting`). The shown-sheet tests DO use a real
/// `NSWindow` so `showDeleteSheet` runs and `deleteSheetPresenter.isShown`
/// becomes true synchronously.
///
/// Headless limitation: the async `beginSheet` dismissal completion is never
/// delivered (no run loop is spun), so the close()/onClose path and `reset()`'s
/// interaction with a genuinely-delivered completion are integration-only —
/// these tests assert the synchronous state transitions, not the async
/// completion (the same constraint `SheetPresenterTests` documents).
///
/// Determinism: each test holds the main actor synchronously from
/// `presentDeleteSheet` through the follow-up call/`stop()`, so the off-main
/// resolution Task can't run until the test `await`s the captured handle's
/// `.value` — event-driven, no polling.
@Suite("DetailAlertsPresenter Tests", .serialized, .admissionGated, .scopedWindows)
@MainActor
struct DetailAlertsPresenterTests {
    private let preferences = makeTestPreferences()

    /// A presenter and the library every VM below is listed in.
    ///
    /// The resolution a delete sheet runs addresses its VM by id, so a VM the
    /// library never held resolves to nothing and answers no attachments — which
    /// is the synchronous path, not the off-main probe these tests are about.
    private func makePresenter() -> (
        presenter: DetailAlertsPresenter, viewModel: VMLibraryViewModel
    ) {
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
        return (DetailAlertsPresenter(viewModel: viewModel), viewModel)
    }

    /// An attachment-free Linux VM: `externalAttachments` returns `[]` without
    /// the off-main probe, so resolution finishes fast.
    private func makeInstance(
        name: String = "Test VM", in viewModel: VMLibraryViewModel,
        hostState: VMHostState = VMHostState()
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(name: name, hostState: hostState)
        viewModel.library.instances.append(instance)
        return instance
    }

    /// A VM carrying an external (non-bundle) storage disk so
    /// `externalAttachments` actually runs its off-main `FileManager.fileExists`
    /// probe — exercising the real async resolve gap.
    private func makeInstanceWithExternalDisk(name: String = "Ext VM", in viewModel: VMLibraryViewModel)
        -> VMInstance
    {
        let instance = VMInstanceFixture.make(name: name) { config in
            config.storageDisks = [
                StorageDisk(
                    path: "/tmp/does-not-exist-\(config.id.uuidString).img", isInternal: false)
            ]
        }
        viewModel.library.instances.append(instance)
        return instance
    }

    // MARK: - Mode (last gesture wins, both directions)

    @Test("⌘⌫ then ⌥⌘⌫ on one VM yields a single sheet upgraded to Immediate")
    func dedupSameVMUpgradesMode() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)

        // ⌘⌫ (Trash) starts the in-flight delete; ⌥⌘⌫ (Immediate) fires before
        // the first resolves and folds in — one sheet, latest gesture wins.
        presenter.presentDeleteSheet(for: vmA, permanently: false)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vmA, permanently: true)
        await task?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
        // The show step reads `pendingDelete` directly, so this is the disposition
        // the sheet would carry — the immediate request is not downgraded to Trash.
        #expect(presenter.pendingDeletePermanentlyForTesting == true)
    }

    @Test("⌥⌘⌫ then ⌘⌫ on one VM downgrades to Trash (last gesture wins both ways)")
    func dedupSameVMDowngradesMode() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)

        presenter.presentDeleteSheet(for: vmA, permanently: true)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vmA, permanently: false)
        await task?.value

        #expect(presenter.pendingCountForTesting == 1)
        // Last wins is symmetric: a later plain ⌘⌫ backs off bypass-Trash.
        #expect(presenter.pendingDeletePermanentlyForTesting == false)
    }

    // MARK: - Single in flight + different-VM retarget (#364)

    @Test("A different-VM request during the resolve retargets the in-flight sheet")
    func differentVMRetargets() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)
        let vmB = makeInstance(name: "B", in: viewModel)

        // vmA starts the in-flight delete; a vmB request before it resolves wins
        // (last gesture) — still a single sheet, now targeting vmB (#364).
        presenter.presentDeleteSheet(for: vmA)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vmB)
        await task?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmB.id)
    }

    @Test("Retargeting to a different VM carries that VM's own disposition")
    func retargetCarriesNewVMMode() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)
        let vmB = makeInstance(name: "B", in: viewModel)

        // The request is a single {instance, permanently} unit, so retargeting
        // swaps both — vmA's Immediate intent does not leak onto vmB's Trash.
        presenter.presentDeleteSheet(for: vmA, permanently: true)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vmB, permanently: false)
        await task?.value

        #expect(presenter.pendingDeleteInstanceIDForTesting == vmB.id)
        #expect(presenter.pendingDeletePermanentlyForTesting == false)
    }

    @Test("A retarget landing DURING the off-main resolve re-resolves the new VM")
    func retargetDuringResolveReResolves() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)
        let vmB = makeInstance(name: "B", in: viewModel)

        // Drive a one-shot vmB request into the gap right after vmA's externals
        // resolve but before the loop checks whether the request changed — this
        // is the across-the-await `continue` re-resolve path (the #364 core) that
        // a synchronous retarget (handled before the Task body runs) can't reach.
        presenter.afterDeleteResolveForTesting = { [weak presenter] in
            presenter?.afterDeleteResolveForTesting = nil
            presenter?.presentDeleteSheet(for: vmB)
        }
        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmB.id)
    }

    // MARK: - Shown sheet is authoritative (no silent drop)

    @Test("A delete gesture while the sheet is shown is ignored, not dropped")
    func ignoreWhileSheetShown() async {
        let (presenter, viewModel) = makePresenter()
        let window = showTestWindow(styleMask: [.titled])
        presenter.start(window: window)
        let vmA = makeInstance(name: "A", in: viewModel)
        let vmB = makeInstance(name: "B", in: viewModel)

        // With a window, the resolved delete actually shows a sheet.
        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value
        #expect(presenter.pendingCountForTesting == 0)  // drained → shown, not queued

        // A different-VM gesture while that sheet is on screen is ignored (the
        // modal sheet is authoritative), NOT coalesced into the in-flight request
        // and then silently dropped when the shown sheet closes.
        presenter.presentDeleteSheet(for: vmB)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
    }

    @Test("A delete after teardown during a shown sheet is accepted, not blocked")
    func deleteAcceptedAfterStopDuringShownSheet() async {
        let (presenter, viewModel) = makePresenter()
        let window = showTestWindow(styleMask: [.titled])
        presenter.start(window: window)
        let vmA = makeInstance(name: "A", in: viewModel)
        let vmB = makeInstance(name: "B", in: viewModel)

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value  // vmA's sheet is shown

        // Teardown must clear the shown-sheet state synchronously; otherwise the
        // ignore guard would still see deleteSheetInstance set and reject the next
        // delete after the pane reappears.
        presenter.stop()
        presenter.start(window: window)
        presenter.presentDeleteSheet(for: vmB)
        await presenter.deleteResolutionTaskForTesting?.value

        #expect(presenter.pendingDeleteInstanceIDForTesting == vmB.id)
        // stop() resets the sheet synchronously, so the prior sheet's lingering
        // `isShown` doesn't stall vmB — its sheet drains immediately (count 0).
        #expect(presenter.pendingCountForTesting == 0)
    }

    // MARK: - Teardown

    @Test("stop() cancels the resolution Task and clears all in-flight state")
    func stopClearsInFlightState() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)

        presenter.presentDeleteSheet(for: vmA, permanently: true)
        let task = presenter.deleteResolutionTaskForTesting
        // The test holds the main actor, so the Task body hasn't run yet —
        // cancellation lands before it can enqueue.
        presenter.stop()
        await task?.value

        #expect(presenter.pendingCountForTesting == 0)
        #expect(presenter.pendingDeleteInstanceIDForTesting == nil)
        // Both halves of the request are cleared symmetrically (no latched mode).
        #expect(presenter.pendingDeletePermanentlyForTesting == nil)
        #expect(presenter.deleteResolutionTaskForTesting == nil)
    }

    @Test("stop() bumps the sheet token so a stale close is invalidated")
    func stopBumpsDeleteSheetToken() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)
        let before = presenter.deleteSheetTokenForTesting

        presenter.presentDeleteSheet(for: vmA)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.stop()
        await task?.value

        #expect(presenter.deleteSheetTokenForTesting == before + 1)
    }

    @Test("A new delete is accepted after teardown clears the in-flight request")
    func dedupResetsAfterStop() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)

        presenter.presentDeleteSheet(for: vmA)
        let firstTask = presenter.deleteResolutionTaskForTesting
        presenter.stop()
        await firstTask?.value  // drain the cancelled Task (it bails, no enqueue)

        // The in-flight request was cleared by stop(); a fresh request is accepted.
        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
    }

    // MARK: - Close-handler token guard (#362 same-VM clobber)

    @Test("A close with the current token clears the in-flight delete")
    func currentTokenCloseClears() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        // The shown sheet's onClose carries the current token — it clears.
        presenter.handleDeleteSheetClosedForTesting(token: presenter.deleteSheetTokenForTesting)
        #expect(presenter.pendingDeleteInstanceIDForTesting == nil)
    }

    @Test("A stale-token close does NOT clobber a newer delete (#362)")
    func staleTokenCloseDoesNotClobber() async {
        let (presenter, viewModel) = makePresenter()
        let vmA = makeInstance(name: "A", in: viewModel)

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        // A stale sheet's late close (older token, e.g. after a stop()/start()
        // bumped the token) must not clear the newer in-flight delete — even for
        // the same VM, which an id-keyed guard could not distinguish.
        presenter.handleDeleteSheetClosedForTesting(token: presenter.deleteSheetTokenForTesting - 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
    }

    // MARK: - Real off-main resolve path (#366)

    @Test("De-dup holds across the real off-main external-resolution probe")
    func dedupAcrossRealOffMainResolve() async {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstanceWithExternalDisk(name: "Ext", in: viewModel)

        // This VM has an external disk, so resolution genuinely suspends on the
        // off-main `FileManager.fileExists` probe (not the synchronous []-return
        // path the other tests take).
        presenter.presentDeleteSheet(for: vm, permanently: false)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vm, permanently: true)
        await task?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vm.id)
        #expect(presenter.pendingDeletePermanentlyForTesting == true)
    }

    // MARK: - Snapshots

    @Test("A second Take Snapshot gesture queued behind another alert is dropped")
    func takeSnapshotSheetDedupesWhileQueued() {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        vm.enter(.running(sessionID: UUID()))

        // No window, so nothing drains: both requests would otherwise sit in
        // `pending` and show two sheets back to back.
        presenter.presentTakeSnapshotSheet(for: vm)
        presenter.presentTakeSnapshotSheet(for: vm)

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.isSnapshotSheetQueuedForTesting)
    }

    @Test("The revert alert on a suspended VM names the suspended session it replaces")
    func revertAlertNamesTheSuspendedSession() throws {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        vm.enter(.suspended)
        // A capturable suspend slot: every predicate a suspended VM is judged
        // by needs one on disk, not just the status.
        defer { VMInstanceFixture.removeBundle(of: vm) }
        try VMInstanceFixture.writeSaveFile(for: vm)
        #expect(vm.isColdPaused)
        let snapshot = VMSnapshot(name: "Before the update", macAddress: nil)

        let alert = presenter.revertSnapshotAlertForTesting(snapshot, for: vm)

        // A cold-paused VM can now check-point before reverting, so the
        // snapshot-first button is offered — but the copy still names the
        // suspended session that revert alone would replace.
        #expect(alert.buttons.contains { $0.title == "Take Snapshot, Then Revert" })
        #expect(alert.message.contains("suspended session"))
    }

    @Test("A running VM's force-stop alert keeps the destructive button off Return")
    func forceStopAlertOrdersItsButtons() {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        vm.enter(.running(sessionID: UUID()))

        let alert = presenter.forceStopAlertForTesting(vm)

        // Added trailing-edge first, so this reads right-to-left on screen:
        // Force Stop on the leading edge, Shut Down on Return.
        #expect(alert.buttons.map(\.title) == ["Shut Down", "Cancel", "Force Stop"])
        #expect(alert.buttons.map(\.role) == [.default, .cancel, .destructive])
    }

    // MARK: - The start-failed removal offer

    private func makeStartFailure(
        _ reason: StartFailedAttachment.Reason, message: String, verb: VMVerb = .start,
        kind: StartFailedAttachment.Kind = .storageDisk
    ) -> StartFailedAttachment {
        StartFailedAttachment(
            verb: verb, kind: kind, reason: reason, id: UUID(), label: "Archive",
            message: message)
    }

    /// The removal edits the configuration and, for a VM holding one, destroys a
    /// saved state — so no keystroke performs it. Same layout the core's own
    /// destructive confirmations get.
    @Test("The removal offer puts its destructive action off Return, with Cancel on Escape")
    func startFailedAlertKeepsTheRemovalOffReturn() {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        let failure = makeStartFailure(.notFound, message: "Storage disk 'Archive' not found.")

        let alert = presenter.startFailedAttachmentAlertForTesting(failure, on: vm)

        #expect(alert.buttons.map(\.title) == ["Remove and Start", "Cancel"])
        #expect(alert.buttons.map(\.role) == [.destructive, .cancel])
        #expect(!alert.buttons.contains { $0.role == .default })
    }

    @Test("The offer heads itself with the bring-up the user asked for")
    func startFailedAlertNamesTheBringUp() {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(name: "Builder", in: viewModel)

        let started = presenter.startFailedAttachmentAlertForTesting(
            makeStartFailure(.notFound, message: "gone"), on: vm)
        let resumed = presenter.startFailedAttachmentAlertForTesting(
            makeStartFailure(.notFound, message: "gone", verb: .resume), on: vm)

        #expect(started.title == "Couldn't Start “Builder”")
        #expect(resumed.title == "Couldn't Resume “Builder”")
    }

    /// Nothing here can tell a deleted file from one on a volume that is not
    /// mounted, so the copy names reconnecting as a condition to check, never as
    /// the cause.
    @Test("A file that isn't there names reconnecting, and claims no cause")
    func startFailedAlertOnAMissingFileNamesTheRetry() {
        let message = DetailAlertsPresenter.startFailedAttachmentMessage(
            makeStartFailure(
                .notFound, message: "Storage disk 'Archive' not found at /Volumes/Ext/a.img."),
            holdsSavedState: false)

        #expect(message.hasPrefix("Storage disk 'Archive' not found at /Volumes/Ext/a.img."))
        #expect(message.contains("If it’s on a disk that isn’t connected, connect it and try again."))
        #expect(!message.contains("was deleted"))
        #expect(!message.contains("may have been"))
        #expect(message.contains("You can also remove “Archive”"))
        #expect(message.contains("re-attach it later in Settings"))
    }

    /// Marking the entry Read Only is the one remedy this app can be sure of —
    /// the builder asks for a writable file only for an entry the VM may write —
    /// and each kind's switch lives in its own Settings section.
    @Test(
        "An unwritable file names the Read Only switch, in the section that carries it",
        arguments: [
            (StartFailedAttachment.Kind.storageDisk, "Storage Disks"),
            (.removableMedia, "Removable Media"),
        ])
    func startFailedAlertOnAnUnwritableFileNamesReadOnly(
        kind: StartFailedAttachment.Kind, section: String
    ) {
        let message = DetailAlertsPresenter.startFailedAttachmentMessage(
            makeStartFailure(
                .notWritable, message: "Archive is not writable: /tmp/a.img.", kind: kind),
            holdsSavedState: false)

        #expect(
            message.contains("Turn on Read Only for it in Settings, under \(section),"), "\(kind)")
        // The file-system side is a condition, not a diagnosis: `isWritableFile`
        // is equally false for a read-only volume and a sandbox denial.
        #expect(
            message.contains("If the file or the disk it’s on is locked or read-only"), "\(kind)")
        #expect(message.contains("You can also remove “Archive”"), "\(kind)")
    }

    /// Settings are locked while a saved state is on disk, so the one remedy
    /// that needs them is not offered to a VM that cannot reach them.
    @Test("An unwritable file on a suspended VM is not sent to Settings")
    func startFailedAlertOnAnUnwritableFileWithASavedStateOmitsReadOnly() {
        let message = DetailAlertsPresenter.startFailedAttachmentMessage(
            makeStartFailure(
                .notWritable, message: "Storage disk 'Archive' is not writable: /tmp/a.img."),
            holdsSavedState: true)

        #expect(!message.contains("Turn on Read Only"))
        #expect(
            message.contains(
                "If the file or the disk it’s on is locked or read-only, make it writable and "
                    + "try again."))
        #expect(
            message.contains(
                "Removing it also discards this virtual machine's saved state"))
    }

    /// Read Only does not make a folder a disk image, and nothing here knows
    /// what the framework objected to — so neither case invents a step.
    @Test(
        "A folder and a refused attach name no remedy",
        arguments: [StartFailedAttachment.Reason.pathIsDirectory, .attachRefused])
    func startFailedAlertNamesNoRemedyWhereNoneIsCertain(reason: StartFailedAttachment.Reason) {
        let message = DetailAlertsPresenter.startFailedAttachmentMessage(
            makeStartFailure(reason, message: "Storage disk 'Archive' is a directory."),
            holdsSavedState: false)

        #expect(message.contains("You can remove “Archive”"), "\(reason)")
        #expect(!message.contains("try again."), "\(reason)")
        #expect(!message.contains("Read Only"), "\(reason)")
    }

    @Test("Discarding a suspended ephemeral session is presented as a revert to the baseline")
    func discardAlertOnAnEphemeralVMNamesTheBaseline() throws {
        let (presenter, viewModel) = makePresenter()
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        var hostState = VMHostState()
        hostState.applyEphemeralMode(enabled: true, baseline: baseline.id)
        let vm = makeInstance(in: viewModel, hostState: hostState)
        vm.enter(.suspended)
        defer { VMInstanceFixture.removeBundle(of: vm) }
        try VMInstanceFixture.writeSaveFile(for: vm)
        vm.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline], currentID: baseline.id))

        let alert = presenter.forceStopAlertForTesting(vm)

        #expect(alert.buttons.contains { $0.title == "Revert to Baseline" })
        #expect(alert.message.contains("Clean install"))
        #expect(!alert.message.contains("permanently delete"))
    }

    @Test("Discarding a suspended VM that isn't ephemeral still names the deletion")
    func discardAlertOnAPlainVMIsUnchanged() throws {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        vm.enter(.suspended)
        defer { VMInstanceFixture.removeBundle(of: vm) }
        try VMInstanceFixture.writeSaveFile(for: vm)

        let alert = presenter.forceStopAlertForTesting(vm)

        #expect(alert.buttons.contains { $0.title == "Discard" })
        #expect(alert.message.contains("permanently delete the saved state"))
    }

    @Test("The revert alert on a live VM offers the snapshot-first path instead")
    func revertAlertOnALiveVMOffersSnapshotFirst() {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        vm.enter(.running(sessionID: UUID()))
        let snapshot = VMSnapshot(name: "Before the update", macAddress: nil)

        let alert = presenter.revertSnapshotAlertForTesting(snapshot, for: vm)

        #expect(alert.buttons.contains { $0.title == "Take Snapshot, Then Revert" })
        #expect(!alert.message.contains("suspended session"))
    }

    @Test("A stopped VM is offered the check-point path, now that it can be captured")
    func revertAlertOnAStoppedVMOffersSnapshotFirst() {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        vm.enter(.stopped)
        let snapshot = VMSnapshot(name: "Before the update", kind: .cold, macAddress: nil)

        let alert = presenter.revertSnapshotAlertForTesting(snapshot, for: vm)

        #expect(alert.buttons.contains { $0.title == "Take Snapshot, Then Revert" })
    }

    @Test("Reverting a live VM to a disks-only snapshot says the session ends, powered off")
    func revertAlertOnAColdTargetNamesThePowerOff() {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        vm.enter(.running(sessionID: UUID()))
        let snapshot = VMSnapshot(name: "Before first boot", kind: .cold, macAddress: nil)

        let alert = presenter.revertSnapshotAlertForTesting(snapshot, for: vm)

        #expect(alert.message.contains("powered off"))
        #expect(alert.message.contains("session it is running now ends"))
    }

    @Test("Reverting a suspended VM to a disks-only snapshot says its saved session is discarded")
    func revertAlertOnAColdTargetFromColdPaused() throws {
        let (presenter, viewModel) = makePresenter()
        let vm = makeInstance(in: viewModel)
        vm.enter(.suspended)
        defer { VMInstanceFixture.removeBundle(of: vm) }
        try VMInstanceFixture.writeSaveFile(for: vm)
        let snapshot = VMSnapshot(name: "Before first boot", kind: .cold, macAddress: nil)

        let alert = presenter.revertSnapshotAlertForTesting(snapshot, for: vm)

        #expect(alert.message.contains("powered off"))
        #expect(alert.message.contains("discarded"))
        // The warm wording, which promises a replacement session, must not leak.
        #expect(!alert.message.contains("replaced by"))
    }

    // MARK: - USB accessory pairing prompts

    /// Collects the answers the prompts under test are given.
    private final class PairingAnswers {
        var answered: [String] = []
    }

    private func pairingRequest(
        named name: String, registryID: UInt64, candidates: [VMInstance],
        answer: @escaping @MainActor (VMInstance?) -> Void
    ) -> USBAccessoryPairingRequest {
        USBAccessoryPairingRequest(
            id: UUID(),
            accessory: USBAccessorySummary(
                registryID: registryID, name: name, vendorID: 0x04E8, productID: 0x6300),
            candidates: candidates,
            answer: answer)
    }

    @Test("Answering one pairing prompt leaves the next one able to be shown")
    func answeringAPairingPromptFreesTheSlot() throws {
        let (presenter, viewModel) = makePresenter()
        let window = showTestWindow(styleMask: [.titled])
        presenter.start(window: window)
        let instance = makeInstance(name: "Work", in: viewModel)
        let answers = PairingAnswers()

        let second = pairingRequest(
            named: "Second", registryID: 2, candidates: [instance],
            answer: { _ in answers.answered.append("second") })
        // The coordinator's own shape: at most one prompt outstanding, and the
        // next raised from inside the answer to the one before it.
        let first = pairingRequest(
            named: "First", registryID: 1, candidates: [instance],
            answer: { _ in
                answers.answered.append("first")
                presenter.presentUSBAccessoryPairing(second)
            })

        presenter.presentUSBAccessoryPairing(first)
        #expect(presenter.isShowingAlertForTesting)

        // "Keep on Mac", delivered the way the sheet handler delivers it.
        #expect(presenter.dismissShownAlertForTesting(.alertSecondButtonReturn))

        // The flag says "a sheet is up", and the sheet is down by the time the
        // action runs — so the second prompt is shown rather than auto-answered
        // as a hold.
        #expect(answers.answered == ["first"])
        #expect(presenter.isShowingAlertForTesting)

        #expect(presenter.dismissShownAlertForTesting(.alertSecondButtonReturn))
        #expect(answers.answered == ["first", "second"])
        #expect(!presenter.isShowingAlertForTesting)
    }

    @Test("A pairing prompt raised while another alert is up is answered as a hold")
    func aPairingPromptBehindAnotherAlertHolds() throws {
        let (presenter, viewModel) = makePresenter()
        let window = showTestWindow(styleMask: [.titled])
        presenter.start(window: window)
        let instance = makeInstance(name: "Work", in: viewModel)
        let answers = PairingAnswers()
        presenter.presentUSBAccessoryPairing(
            pairingRequest(
                named: "First", registryID: 1, candidates: [instance],
                answer: { _ in answers.answered.append("first") }))
        #expect(presenter.isShowingAlertForTesting)

        presenter.presentUSBAccessoryPairing(
            pairingRequest(
                named: "Second", registryID: 2, candidates: [instance],
                answer: { answers.answered.append($0 == nil ? "hold" : "pass") }))

        // Nobody asked for this one, and the coordinator waits on its answer —
        // so it is answered now rather than queued behind a sheet that may
        // never be dismissed.
        #expect(answers.answered == ["hold"])
    }

    // MARK: - The guest account a VM still owes

    /// Collects the answers the account prompts under test are given.
    private final class AccountAnswers {
        var answered: [GuestAccountPasswordAnswer] = []
    }

    private func accountRequest(
        vmName: String = "Sequoia", vmID: UUID = Self.accountVMID, answers: AccountAnswers
    ) -> GuestAccountPasswordRequest {
        GuestAccountPasswordRequest(
            prompt: GuestAccountPrompt(
                vm: VMSummary(
                    id: vmID, name: vmName, status: "stopped", ipAddress: .unavailable),
                username: "ada", fullName: "Ada Lovelace",
                message: "\u{201C}\(vmName)\u{201D} creates the macOS account."),
            answer: { answers.answered.append($0) })
    }

    /// One identifier across requests, so two prompts for it are the same VM
    /// asking twice — which is what the presenter tells apart.
    private static let accountVMID =
        UUID(uuidString: "5E00A1A0-0000-4000-8000-000000000001") ?? UUID()

    @Test("An account prompt with no window to ask in starts nothing")
    func anAccountPromptWithNoWindowIsCancelled() {
        let (presenter, _) = makePresenter()
        let answers = AccountAnswers()

        presenter.presentGuestAccountPassword(accountRequest(answers: answers))

        // The start is suspended on this answer, so it is answered now rather
        // than queued behind a window that may never arrive — and cancelled
        // rather than waved through, because proceeding retracts the account
        // and only the user may decide that.
        #expect(answers.answered == [.cancelled])
        #expect(presenter.pendingCountForTesting == 0)
    }

    @Test("An account prompt raised while another alert is up starts nothing")
    func anAccountPromptBehindAnotherAlertIsCancelled() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        presenter.presentError("Something else", title: "Couldn't Start")
        #expect(presenter.isShowingAlertForTesting)
        let answers = AccountAnswers()

        presenter.presentGuestAccountPassword(accountRequest(answers: answers))

        #expect(answers.answered == [.cancelled])
    }

    @Test("A second Start while the prompt is up is turned away, not asked twice")
    func aSecondStartUnderThePromptIsTurnedAway() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        let first = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: first))
        let second = AccountAnswers()

        // The status-item menu and a detached display window are not blocked by
        // a window-modal sheet, so a second Start really can arrive here.
        presenter.presentGuestAccountPassword(accountRequest(answers: second))

        // The newcomer is answered so its start does not hang, and the sheet
        // already asking about this VM is brought forward — the click lands on
        // the question gating the start. Only the answer is assertable here;
        // that the window comes to the front is not observable headlessly.
        #expect(second.answered == [.cancelled])
        #expect(first.answered.isEmpty)
        #expect(presenter.isShowingAlertForTesting)
    }

    @Test("Tearing the window down answers the start suspended on the prompt")
    func stoppingAnswersTheWaitingStart() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))

        presenter.stop()

        // A suspended `withCheckedContinuation` nothing resumes strands that
        // start for the rest of the session.
        #expect(answers.answered == [.cancelled])
    }

    @Test("Tearing the window down takes the sheet with it, and frees the slot")
    func stoppingDismissesTheShownAlert() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        presenter.presentGuestAccountPassword(accountRequest(answers: AccountAnswers()))
        #expect(presenter.isShowingAlertForTesting)

        presenter.stop()

        // Left up, the sheet stays on a window that is going away with buttons
        // that answer nothing, and the flag under it wedges the queue for the
        // next window this presenter serves.
        #expect(!presenter.isShowingAlertForTesting)
        #expect(!presenter.dismissShownAlertForTesting(.alertFirstButtonReturn))

        // The freed slot really is free: the next window's first request shows.
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        presenter.presentError("Something else", title: "Couldn't Start")
        #expect(presenter.isShowingAlertForTesting)
    }

    @Test("A pairing prompt on screen when the window goes is answered as a hold")
    func stoppingHoldsAShownPairingPrompt() {
        let (presenter, viewModel) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        let instance = makeInstance(name: "Work", in: viewModel)
        let answers = PairingAnswers()
        presenter.presentUSBAccessoryPairing(
            pairingRequest(
                named: "First", registryID: 1, candidates: [instance],
                answer: { answers.answered.append($0 == nil ? "hold" : "pass") }))
        #expect(presenter.isShowingAlertForTesting)

        presenter.stop()

        // The coordinator holds its next prompt until this one answers, so a
        // sheet dismissed without a click still owes it one — and the accessory
        // staying with the Mac is what an unanswerable question means.
        #expect(answers.answered == ["hold"])
    }

    @Test("A prompt put back up after a refusal is answered by the teardown too")
    func stoppingAnswersARefusedPrompt() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))
        // "Set Up Account" with the fields untouched: the refusal sends the
        // request back through the queue, which `stop()` drops.
        #expect(presenter.dismissShownAlertForTesting(.alertFirstButtonReturn))

        presenter.stop()

        #expect(answers.answered == [.cancelled])
    }

    @Test("A prompt answered once is not answered again by the teardown")
    func stoppingDoesNotAnswerTwice() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))
        #expect(presenter.dismissShownAlertForTesting(.alertSecondButtonReturn))

        presenter.stop()

        // Resuming a checked continuation twice traps, so this is the other
        // half of "exactly once".
        #expect(answers.answered == [.skip])
    }

    @Test("Skip Setup answers the waiting start and frees the slot")
    func skipSetupAnswersAndFreesTheSlot() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))
        #expect(presenter.isShowingAlertForTesting)

        #expect(presenter.dismissShownAlertForTesting(.alertSecondButtonReturn))

        #expect(answers.answered == [.skip])
        #expect(!presenter.isShowingAlertForTesting)
    }

    @Test("Cancel answers with no start")
    func cancelAnswersWithNoStart() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))

        #expect(presenter.dismissShownAlertForTesting(.alertThirdButtonReturn))

        #expect(answers.answered == [.cancelled])
        #expect(!presenter.isShowingAlertForTesting)
    }

    @Test("A refused password puts the sheet back up instead of answering the start")
    func aRefusedPasswordReturnsToTheSheet() {
        let (presenter, _) = makePresenter()
        presenter.start(window: showTestWindow(styleMask: [.titled]))
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))

        // "Set Up Account" with both fields untouched: the refusal is the
        // form's own, and the start hears nothing about it.
        #expect(presenter.dismissShownAlertForTesting(.alertFirstButtonReturn))
        #expect(answers.answered.isEmpty)
        #expect(presenter.isShowingAlertForTesting)

        #expect(presenter.dismissShownAlertForTesting(.alertThirdButtonReturn))
        #expect(answers.answered == [.cancelled])
        #expect(!presenter.isShowingAlertForTesting)
    }
}
