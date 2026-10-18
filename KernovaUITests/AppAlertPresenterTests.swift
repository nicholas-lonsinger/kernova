import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers `AppAlertPresenter` against the app's real windows: the library
/// window a ``Harness`` shows and closes, and display windows for routing that
/// needs one. A window closed under the presenter is how a test takes the
/// surface away; a sheet ended with a button's return code is how it clicks.
///
/// The delete-sheet de-dup state machine (issue #362 and follow-ups
/// #364/#366): one sheet in flight at a time, the latest gesture winning (mode
/// upgrade *and* different-VM retarget) up until the sheet is shown, a
/// cancellable off-main resolution, and a per-sheet token so a stale close
/// can't clobber a newer delete. Most of those tests show no window, so the
/// resolved show waits with nowhere to go (`waitingCountForTesting`).
///
/// Determinism: each test holds the main actor synchronously from
/// `presentDeleteSheet` through the follow-up call, so the off-main
/// resolution Task can't run until the test `await`s the captured handle's
/// `.value` — event-driven, no polling. AppKit ends a sheet synchronously in
/// the test host, running its handler and posting `didEndSheet` in the same
/// turn.
@Suite("AppAlertPresenter Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct AppAlertPresenterTests {
    private let preferences = makeTestPreferences()

    /// A presenter over a library and the app's window registry, with the
    /// library window shown and closed on demand.
    @MainActor
    final class Harness {
        let viewModel: VMLibraryViewModel
        let registry: AppWindowRegistry
        let presenter: AppAlertPresenter
        let presence = TestAppPresence()
        let storage = MockVMStorageService()
        let fileSystem = MockFileSystem()

        init(preferences: AppPreferences) {
            viewModel = makeLibraryViewModel(
                preferences: preferences, storageService: storage, fileSystem: fileSystem)
            registry = makeWindowRegistry(viewModel, presence: presence)
            presenter = AppAlertPresenter(viewModel: viewModel, windows: registry)
        }

        /// The library window, shown — what an alert about no VM, or one with
        /// no window of its own, goes to.
        @discardableResult
        func showLibrary() -> NSWindow {
            registry.showLibrary(bringToFront: false)
            guard let window = registry.libraryWindow else { preconditionFailure("showLibrary made no window") }
            return window
        }

        func closeLibrary() {
            registry.libraryWindow?.close()
        }

        /// Whether a sheet is on the library window.
        var isShowingAlert: Bool { registry.libraryWindow?.attachedSheet != nil }

        /// Ends the library window's sheet with `response` — the button it
        /// names, as a click would — and answers whether there was one.
        @discardableResult
        func dismissShownAlert(_ response: NSApplication.ModalResponse) -> Bool {
            guard let window = registry.libraryWindow, let sheet = window.attachedSheet else {
                return false
            }
            window.endSheet(sheet, returnCode: response)
            return true
        }
    }

    private func makeHarness() -> Harness { Harness(preferences: preferences) }

    /// An attachment-free Linux VM: `externalAttachments` returns `[]` without
    /// the off-main probe, so resolution finishes fast.
    private func makeInstance(
        name: String = "Test VM", in viewModel: VMLibraryViewModel,
        hostState: VMHostState = VMHostState()
    ) -> VMInstance {
        let instance = viewModel.library.admitFixture(name: name, hostState: hostState)
        return instance
    }

    /// A VM carrying an external (non-bundle) storage disk so
    /// `externalAttachments` actually runs its off-main `FileManager.fileExists`
    /// probe — exercising the real async resolve gap.
    private func makeInstanceWithExternalDisk(name: String = "Ext VM", in viewModel: VMLibraryViewModel)
        -> VMInstance
    {
        let instance = viewModel.library.admitFixture(name: name) { config in
            config.storageDisks = [
                StorageDisk(
                    path: "/tmp/does-not-exist-\(config.id.uuidString).img", isInternal: false)
            ]
        }
        return instance
    }

    // MARK: - Mode (last gesture wins, both directions)

    @Test("⌥⌘⌫ then ⌘⌫ on one VM downgrades to Trash (last gesture wins both ways)")
    func dedupSameVMDowngradesMode() async {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        let vmA = makeInstance(name: "A", in: viewModel)

        presenter.presentDeleteSheet(for: vmA, permanently: true)
        let task = presenter.deleteResolutionForTesting(of: vmA.id)
        presenter.presentDeleteSheet(for: vmA, permanently: false)
        await task?.value

        #expect(presenter.waitingCountForTesting == 1)
        // Last wins is symmetric: a later plain ⌘⌫ backs off bypass-Trash.
        #expect(presenter.deleteDispositionsForTesting == [vmA.id: false])
    }

    // MARK: - One delete per VM

    @Test("A delete for a second VM is a sheet of its own, with its own disposition")
    func eachVMHasItsOwnDelete() async {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        let vmA = makeInstance(name: "A", in: viewModel)
        let vmB = makeInstance(name: "B", in: viewModel)

        presenter.presentDeleteSheet(for: vmA, permanently: true)
        presenter.presentDeleteSheet(for: vmB, permanently: false)
        await presenter.deleteResolutionForTesting(of: vmA.id)?.value
        await presenter.deleteResolutionForTesting(of: vmB.id)?.value

        // No window, so both wait — neither retargets nor drops the other.
        #expect(presenter.waitingCountForTesting == 2)
        #expect(presenter.deleteDispositionsForTesting == [vmA.id: true, vmB.id: false])
    }

    // MARK: - Shown sheet is authoritative (no silent drop)

    @Test("A gesture for the VM whose delete sheet is up is ignored; another VM's waits its turn")
    func shownSheetIgnoresItsVMAndQueuesAnother() async {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        h.showLibrary()
        let vmA = makeInstance(name: "A", in: viewModel)
        let vmB = makeInstance(name: "B", in: viewModel)

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionForTesting(of: vmA.id)?.value
        #expect(presenter.waitingCountForTesting == 0)  // drained → shown, not queued

        // The modal sheet is authoritative: a repeat gesture cannot change it.
        presenter.presentDeleteSheet(for: vmA, permanently: true)
        #expect(presenter.deleteDispositionsForTesting == [vmA.id: false])

        presenter.presentDeleteSheet(for: vmB)
        await presenter.deleteResolutionForTesting(of: vmB.id)?.value
        #expect(presenter.waitingCountForTesting == 1)

        #expect(h.dismissShownAlert(.cancel))

        #expect(h.isShowingAlert)
        #expect(presenter.waitingCountForTesting == 0)
        #expect(presenter.deleteDispositionsForTesting == [vmB.id: false])
    }

    @Test("A delete after the window under a shown sheet closed is accepted, not blocked")
    func deleteAcceptedAfterTheWindowUnderTheSheetCloses() async {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        h.showLibrary()
        let vmA = makeInstance(name: "A", in: viewModel)

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionForTesting(of: vmA.id)?.value  // vmA's sheet is shown

        // The window closing must end the shown delete synchronously;
        // otherwise the next gesture for the VM would find it still on screen.
        h.closeLibrary()
        h.showLibrary()
        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionForTesting(of: vmA.id)?.value

        #expect(presenter.deleteDispositionsForTesting == [vmA.id: false])
        // The close took the prior sheet down with it, so the new sheet goes
        // up at once rather than waiting.
        #expect(presenter.waitingCountForTesting == 0)
        #expect(h.isShowingAlert)
    }

    // MARK: - Teardown

    @Test("Closing the window under the delete sheet cancels it and clears all in-flight state")
    func closingTheWindowClearsInFlightState() async {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        h.showLibrary()
        let vmA = makeInstance(name: "A", in: viewModel)
        presenter.presentDeleteSheet(for: vmA, permanently: true)
        await presenter.deleteResolutionForTesting(of: vmA.id)?.value
        #expect(h.isShowingAlert)

        h.closeLibrary()

        #expect(presenter.waitingCountForTesting == 0)
        #expect(presenter.deleteDispositionsForTesting.isEmpty)
        #expect(presenter.deleteResolutionForTesting(of: vmA.id) == nil)
    }

    // MARK: - Real off-main resolve path (#366)

    @Test("De-dup holds across the real off-main external-resolution probe")
    func dedupAcrossRealOffMainResolve() async {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        let vm = makeInstanceWithExternalDisk(name: "Ext", in: viewModel)

        // This VM has an external disk, so resolution genuinely suspends on the
        // off-main `FileManager.fileExists` probe (not the synchronous []-return
        // path the other tests take).
        presenter.presentDeleteSheet(for: vm, permanently: false)
        let task = presenter.deleteResolutionForTesting(of: vm.id)
        presenter.presentDeleteSheet(for: vm, permanently: true)
        await task?.value

        #expect(presenter.waitingCountForTesting == 1)
        #expect(presenter.deleteDispositionsForTesting == [vm.id: true])
    }

    // MARK: - Files a delete kept

    @Test("A delete whose kept file can't be trashed shows the files-kept report on the library window")
    func filesKeptReportShowsOnTheLibrary() async {
        let h = makeHarness()
        h.viewModel.presenter = h.presenter
        let library = h.showLibrary()
        h.fileSystem.setTrashError(CocoaError(.fileWriteNoPermission))
        let lockedID = UUID()
        let vm = h.viewModel.library.admitFixture(name: "Leaving") {
            $0.removableMedia = [
                RemovableMediaItem(
                    id: lockedID, path: "/tmp/kernova-locked-\(UUID().uuidString).iso", readOnly: true)
            ]
        }
        h.storage.setConfiguration(vm.configuration, at: vm.bundleURL)

        await h.viewModel.delete(vm, deletingExternalIDs: [lockedID])

        // The report is raised about the VM after it left the library, so it
        // goes up as one about no VM rather than being dropped for its absence.
        #expect(h.viewModel.instances.isEmpty)
        #expect(sheetText(on: library).contains("Couldn\u{2019}t Move a File to the Trash"))
    }

    // MARK: - Snapshots

    @Test("A second Take Snapshot gesture queued behind another alert is dropped")
    func takeSnapshotSheetDedupesWhileQueued() {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        let vm = makeInstance(in: viewModel)
        vm.activity.placeForTesting(.running(sessionID: UUID()))

        // No window, so nothing drains: both requests would otherwise sit in
        // `pending` and show two sheets back to back.
        presenter.presentTakeSnapshotSheet(for: vm, purpose: .restorePoint)
        presenter.presentTakeSnapshotSheet(for: vm, purpose: .restorePoint)

        #expect(presenter.waitingCountForTesting == 1)
    }

    @Test("A Take Snapshot gesture for the VM whose sheet is up is ignored; another VM's waits its turn")
    func takeSnapshotSheetIgnoresItsVMAndQueuesAnother() throws {
        let h = makeHarness()
        let library = h.showLibrary()
        let vmX = makeInstance(name: "X", in: h.viewModel)
        let vmY = makeInstance(name: "Y", in: h.viewModel)
        #expect(vmX.snapshotCaptureMode != nil)
        #expect(vmY.snapshotCaptureMode != nil)

        h.presenter.presentTakeSnapshotSheet(for: vmX, purpose: .restorePoint)
        let xSheet = try #require(library.attachedSheet)
        #expect(h.presenter.waitingCountForTesting == 0)

        h.presenter.presentTakeSnapshotSheet(for: vmX, purpose: .restorePoint)
        #expect(library.attachedSheet === xSheet)
        #expect(h.presenter.waitingCountForTesting == 0)

        h.presenter.presentTakeSnapshotSheet(for: vmY, purpose: .restorePoint)
        #expect(library.attachedSheet === xSheet)
        #expect(h.presenter.waitingCountForTesting == 1)

        #expect(h.dismissShownAlert(.cancel))

        let ySheet = try #require(library.attachedSheet)
        #expect(ySheet !== xSheet)
        #expect(h.presenter.waitingCountForTesting == 0)
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
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        h.showLibrary()
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
        #expect(h.isShowingAlert)

        // "Keep on Mac", delivered the way the sheet handler delivers it.
        #expect(h.dismissShownAlert(.alertSecondButtonReturn))

        // The flag says "a sheet is up", and the sheet is down by the time the
        // action runs — so the second prompt is shown rather than auto-answered
        // as a hold.
        #expect(answers.answered == ["first"])
        #expect(h.isShowingAlert)

        #expect(h.dismissShownAlert(.alertSecondButtonReturn))
        #expect(answers.answered == ["first", "second"])
        #expect(!h.isShowingAlert)
    }

    @Test("A pairing prompt raised while another alert is up is answered as a hold")
    func aPairingPromptBehindAnotherAlertHolds() throws {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        h.showLibrary()
        let instance = makeInstance(name: "Work", in: viewModel)
        let answers = PairingAnswers()
        presenter.presentUSBAccessoryPairing(
            pairingRequest(
                named: "First", registryID: 1, candidates: [instance],
                answer: { _ in answers.answered.append("first") }))
        #expect(h.isShowingAlert)

        presenter.presentUSBAccessoryPairing(
            pairingRequest(
                named: "Second", registryID: 2, candidates: [instance],
                answer: { answers.answered.append($0 == nil ? "hold" : "pass") }))

        // Nobody asked for this one, and the coordinator waits on its answer —
        // so it is answered now rather than queued behind a sheet that may
        // never be dismissed.
        #expect(answers.answered == ["hold"])
    }

    // MARK: - A confirmation a verb waits on

    private func confirmationRequest(answers: Box<[PresenterAnswer<Bool>]>) -> ConfirmationRequest {
        ConfirmationRequest(
            instance: VMInstanceFixture.make(name: "Twin"),
            prompt: ConfirmationPrompt(
                kind: .startBesideSharedMachineIdentity, title: "Start \u{201C}Twin\u{201D} Anyway?",
                message: "\u{201C}Twin\u{201D} has the same machine ID as \u{201C}Live\u{201D}, which is active.",
                confirmTitle: "Start Anyway", dismissTitle: "Cancel"),
            answer: { answers.value.append($0) })
    }

    /// Holds what the requests under test are answered with.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    @Test("A confirmation's buttons answer the verb waiting on it, once")
    func aConfirmationIsAnsweredByItsButton() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        let answers = Box<[PresenterAnswer<Bool>]>([])

        presenter.presentConfirmationRequest(confirmationRequest(answers: answers))
        #expect(h.isShowingAlert)
        #expect(h.dismissShownAlert(.alertFirstButtonReturn))
        h.closeLibrary()

        #expect(answers.value == [.answered(true)])
    }

    @Test("A confirmation with no window to ask in is answered unasked at once")
    func aConfirmationWithNoWindowIsUnasked() {
        let h = makeHarness()
        let presenter = h.presenter
        let answers = Box<[PresenterAnswer<Bool>]>([])

        presenter.presentConfirmationRequest(confirmationRequest(answers: answers))

        // The verb is suspended on this answer; a queue would hold it until a
        // window that may never come back.
        #expect(answers.value == [.unasked])
        #expect(presenter.waitingCountForTesting == 0)
    }

    @Test("A confirmation raised while another alert is up is answered unasked at once")
    func aConfirmationBehindAnotherAlertIsUnasked() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        presenter.presentError("Something else", title: "Couldn't Start", about: .library)
        let answers = Box<[PresenterAnswer<Bool>]>([])

        presenter.presentConfirmationRequest(confirmationRequest(answers: answers))

        #expect(answers.value == [.unasked])
        #expect(presenter.waitingCountForTesting == 0)
    }

    @Test("Tearing the window down answers the confirmation on screen unasked")
    func stoppingUnasksTheShownConfirmation() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        let answers = Box<[PresenterAnswer<Bool>]>([])
        presenter.presentConfirmationRequest(confirmationRequest(answers: answers))
        #expect(h.isShowingAlert)

        h.closeLibrary()

        #expect(answers.value == [.unasked])
    }

    @Test("Cancel on a confirmation answers that the user declined")
    func cancelDeclinesAConfirmation() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        let answers = Box<[PresenterAnswer<Bool>]>([])
        presenter.presentConfirmationRequest(confirmationRequest(answers: answers))

        #expect(h.dismissShownAlert(.alertSecondButtonReturn))

        #expect(answers.value == [.answered(false)])
    }

    // MARK: - A step refusal's routes

    private static let clone = VMSummary(
        id: UUID(), name: "Clone", status: "suspended", ipAddress: .unavailable,
        heldByAnotherCopy: false)

    private static let ownNetwork = ConfigurationEntry(key: "network.membership", value: "isolated")

    private static let routes = [
        StepRoute(
            title: "Move to a Network of Its Own",
            steps: [
                .setConfiguration(
                    vm: clone, assignments: [ownNetwork])
            ], ending: .refusedVerb),
        StepRoute(
            title: "Use a New MAC Address",
            steps: [
                .discardSavedState(vm: clone),
                .setConfiguration(vm: clone, assignments: [ConfigurationEntry(key: "network.mac", value: "new")]),
            ], ending: .refusedVerb),
        StepRoute(
            title: "Turn Off Networking",
            steps: [
                .discardSavedState(vm: clone),
                .setConfiguration(vm: clone, assignments: [ConfigurationEntry(key: "network.mode", value: "none")]),
            ], ending: .start(vm: clone)),
    ]

    private func routeRequest(
        answers: Box<[PresenterAnswer<StepRoute?>]>, then verbTitle: String? = "Resume"
    ) -> StepRouteRequest {
        StepRouteRequest(
            instance: VMInstanceFixture.make(),
            requirement: StepRequirement(
                title: "Duplicate MAC Address", message: "Change its network first.",
                routes: Self.routes),
            verbTitle: verbTitle, answer: { answers.value.append($0) })
    }

    @Test("The route alert names each route then the request it ends with, and keeps a discarding route off Return")
    func routeAlertOrdersItsButtons() {
        let request = routeRequest(answers: Box([]))
        let alert = AlertConfiguration(
            offering: request.requirement, then: request.verbTitle, choose: { _ in })

        #expect(alert.title == "Duplicate MAC Address")
        #expect(alert.message == "Change its network first.")
        #expect(
            alert.buttons.map(\.title) == [
                "Move to a Network of Its Own and Resume", "Cancel",
                "Use a New MAC Address and Resume", "Turn Off Networking and Start",
            ])
        #expect(alert.buttons.map(\.role) == [.default, .cancel, .destructive, .destructive])

        let edit = AlertConfiguration(
            offering: request.requirement, then: nil, choose: { _ in })
        #expect(edit.buttons.first?.title == "Move to a Network of Its Own")
    }

    @Test("Each route button answers the verb with its route, and Cancel with none")
    func routeButtonsAnswerTheVerb() {
        for (response, expected): (NSApplication.ModalResponse, StepRoute?) in [
            (.alertFirstButtonReturn, Self.routes[0]), (.alertSecondButtonReturn, nil),
            (.alertThirdButtonReturn, Self.routes[1]),
        ] {
            let h = makeHarness()
            let presenter = h.presenter
            h.showLibrary()
            let answers = Box<[PresenterAnswer<StepRoute?>]>([])

            presenter.presentStepRoutes(routeRequest(answers: answers))
            #expect(h.dismissShownAlert(response))
            h.closeLibrary()

            #expect(answers.value == [.answered(expected)], "\(response)")
        }
    }

    @Test("A route question with nowhere to ask is answered unasked, and one on screen when the window goes")
    func routeQuestionWithNowhereToAskIsUnasked() {
        let h = makeHarness()
        let presenter = h.presenter
        let unshown = Box<[PresenterAnswer<StepRoute?>]>([])
        presenter.presentStepRoutes(routeRequest(answers: unshown))
        #expect(unshown.value == [.unasked])

        h.showLibrary()
        let shown = Box<[PresenterAnswer<StepRoute?>]>([])
        presenter.presentStepRoutes(routeRequest(answers: shown))
        h.closeLibrary()
        #expect(shown.value == [.unasked])
    }

    // MARK: - The guest account a VM still owes

    /// Collects the answers the account prompts under test are given.
    private final class AccountAnswers {
        var answered: [PresenterAnswer<GuestAccountPasswordAnswer>] = []
    }

    private func accountRequest(
        vmName: String = "Sequoia", vmID: UUID = Self.accountVMID, answers: AccountAnswers
    ) -> GuestAccountPasswordRequest {
        GuestAccountPasswordRequest(
            prompt: GuestAccountPrompt(
                vm: VMSummary(
                    id: vmID, name: vmName, status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false),
                username: "ada", fullName: "Ada Lovelace",
                message: "\u{201C}\(vmName)\u{201D} creates the macOS account."),
            answer: { answers.answered.append($0) })
    }

    /// One identifier across requests, so two prompts for it are the same VM
    /// asking twice — which is what the presenter tells apart.
    private static let accountVMID =
        UUID(uuidString: "5E00A1A0-0000-4000-8000-000000000001") ?? UUID()

    @Test("An account prompt with no window to ask in is answered unasked")
    func anAccountPromptWithNoWindowIsUnasked() {
        let h = makeHarness()
        let presenter = h.presenter
        let answers = AccountAnswers()

        presenter.presentGuestAccountPassword(accountRequest(answers: answers))

        // The start is suspended on this answer, so it is answered now rather
        // than queued behind a window that may never arrive.
        #expect(answers.answered == [.unasked])
        #expect(presenter.waitingCountForTesting == 0)
    }

    @Test("An account prompt raised while another alert is up is answered unasked")
    func anAccountPromptBehindAnotherAlertIsUnasked() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        presenter.presentError("Something else", title: "Couldn't Start", about: .library)
        #expect(h.isShowingAlert)
        let answers = AccountAnswers()

        presenter.presentGuestAccountPassword(accountRequest(answers: answers))

        #expect(answers.answered == [.unasked])
    }

    @Test("A second Start while the prompt is up is turned away, not asked twice")
    func aSecondStartUnderThePromptIsTurnedAway() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        let first = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: first))
        let second = AccountAnswers()

        // The status-item menu and a detached display window are not blocked by
        // a window-modal sheet, so a second Start really can arrive here.
        presenter.presentGuestAccountPassword(accountRequest(answers: second))

        // The newcomer is answered so its start does not hang, and the sheet
        // already asking about this VM is brought forward — the click lands on
        // the question gating the start.
        #expect(second.answered == [.answered(.cancelled)])
        #expect(first.answered.isEmpty)
        #expect(h.isShowingAlert)
        #expect(h.presence.requests == [.activate])
    }

    @Test(
        "Tearing the window down answers the start suspended on the prompt, takes the sheet with it, and frees the slot"
    )
    func stoppingAnswersTheWaitingStart() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))
        #expect(h.isShowingAlert)

        h.closeLibrary()

        // A suspended `withCheckedContinuation` nothing resumes strands that
        // start for the rest of the session; the user answered nothing.
        #expect(answers.answered == [.unasked])
        #expect(!h.isShowingAlert)
        #expect(!h.dismissShownAlert(.alertFirstButtonReturn))

        h.showLibrary()
        presenter.presentError("Something else", title: "Couldn't Start", about: .library)
        #expect(h.isShowingAlert)
    }

    @Test("A pairing prompt on screen when the window goes is answered as a hold")
    func stoppingHoldsAShownPairingPrompt() {
        let h = makeHarness()
        let (presenter, viewModel) = (h.presenter, h.viewModel)
        h.showLibrary()
        let instance = makeInstance(name: "Work", in: viewModel)
        let answers = PairingAnswers()
        presenter.presentUSBAccessoryPairing(
            pairingRequest(
                named: "First", registryID: 1, candidates: [instance],
                answer: { answers.answered.append($0 == nil ? "hold" : "pass") }))
        #expect(h.isShowingAlert)

        h.closeLibrary()

        // The coordinator holds its next prompt until this one answers, so a
        // sheet dismissed without a click still owes it one — and the accessory
        // staying with the Mac is what an unanswerable question means.
        #expect(answers.answered == ["hold"])
    }

    @Test("A prompt put back up after a refusal is answered by the teardown too")
    func stoppingAnswersARefusedPrompt() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))
        // "Set Up Account" with the fields untouched: the refusal sends the
        // request back through the queue, which `stop()` drops.
        #expect(h.dismissShownAlert(.alertFirstButtonReturn))

        h.closeLibrary()

        #expect(answers.answered == [.unasked])
    }

    @Test("A prompt answered once is not answered again by the teardown")
    func stoppingDoesNotAnswerTwice() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))
        #expect(h.isShowingAlert)
        #expect(h.dismissShownAlert(.alertSecondButtonReturn))
        #expect(answers.answered == [.answered(.skip)])
        #expect(!h.isShowingAlert)

        h.closeLibrary()

        // Resuming a checked continuation twice traps, so this is the other
        // half of "exactly once".
        #expect(answers.answered == [.answered(.skip)])
    }

    @Test("A refused password puts the sheet back up instead of answering the start")
    func aRefusedPasswordReturnsToTheSheet() {
        let h = makeHarness()
        let presenter = h.presenter
        h.showLibrary()
        let answers = AccountAnswers()
        presenter.presentGuestAccountPassword(accountRequest(answers: answers))

        // "Set Up Account" with both fields untouched: the refusal is the
        // form's own, and the start hears nothing about it.
        #expect(h.dismissShownAlert(.alertFirstButtonReturn))
        #expect(answers.answered.isEmpty)
        #expect(h.isShowingAlert)

        #expect(h.dismissShownAlert(.alertThirdButtonReturn))
        #expect(answers.answered == [.answered(.cancelled)])
        #expect(!h.isShowingAlert)
    }

    // MARK: - One queue per window

    private func makeRunningInstance(
        name: String, guestOS: VMGuestOS = .linux, in viewModel: VMLibraryViewModel
    ) -> VMInstance {
        viewModel.library.admitFixture(name: name, guestOS: guestOS, phase: .running(sessionID: UUID()))
    }

    /// `instance`'s display window, popped out.
    private func showDisplayWindow(for instance: VMInstance, in h: Harness) throws -> NSWindow {
        h.registry.displayPlacement.showDisplayWindow(for: instance)
        return try #require(h.registry.displayPlacement.window(for: instance.id))
    }

    /// Every label and button title on the sheet attached to `window` — an
    /// alert's title, message, and buttons among them.
    private func sheetText(on window: NSWindow) -> [String] {
        func labels(in view: NSView) -> [String] {
            let own =
                (view as? NSTextField).map { [$0.stringValue] }
                ?? (view as? NSButton).map { [$0.title] } ?? []
            return own + view.subviews.flatMap(labels(in:))
        }
        return window.attachedSheet?.contentView.map(labels(in:)) ?? []
    }

    @Test("The guest agent disk notice goes up on its VM's display window")
    func agentDiskNoticeRoutesToItsDisplayWindow() throws {
        let h = makeHarness()
        let vm = makeRunningInstance(name: "Guest", guestOS: .macOS, in: h.viewModel)
        let display = try showDisplayWindow(for: vm, in: h)

        h.presenter.presentInstallerMounted(for: vm, purpose: .install, delivery: .usb)

        #expect(sheetText(on: display).contains("Installer Mounted"))
        #expect(h.presenter.waitingCountForTesting == 0)
    }

    @Test("An alert waiting on one window does not hold up one for another, and each window keeps its order")
    func windowsQueueIndependently() throws {
        let h = makeHarness()
        let vmA = makeRunningInstance(name: "A", in: h.viewModel)
        let vmB = makeRunningInstance(name: "B", in: h.viewModel)
        let displayA = try showDisplayWindow(for: vmA, in: h)
        let displayB = try showDisplayWindow(for: vmB, in: h)

        h.presenter.presentError("One.", title: "First Notice", about: .vm(vmA))
        h.presenter.presentError("Two.", title: "Second Notice", about: .vm(vmA))
        h.presenter.presentError("Three.", title: "Other Notice", about: .vm(vmB))

        #expect(sheetText(on: displayA).contains("First Notice"))
        #expect(sheetText(on: displayB).contains("Other Notice"))
        #expect(h.presenter.waitingCountForTesting == 1)

        let shown = try #require(displayA.attachedSheet)
        displayA.endSheet(shown, returnCode: .alertFirstButtonReturn)

        #expect(sheetText(on: displayA).contains("Second Notice"))
        #expect(h.presenter.waitingCountForTesting == 0)
    }

    @Test("A display window closing sends its alert and those waiting for it to the library window")
    func closingADisplayWindowReroutesItsAlerts() throws {
        let h = makeHarness()
        let vm = makeRunningInstance(name: "Work", in: h.viewModel)
        let display = try showDisplayWindow(for: vm, in: h)
        let isListed: (UUID) -> Bool = { id in h.viewModel.instances.contains { $0.id == id } }
        h.presenter.presentError("Shown.", title: "Shown Notice", about: .vm(vm))
        h.presenter.presentError("Waiting.", title: "Waiting Notice", about: .vm(vm))
        #expect(sheetText(on: display).contains("Shown Notice"))
        #expect(h.presenter.waitingCountForTesting == 1)

        display.close()

        #expect(h.presenter.waitingCountForTesting == 2)
        #expect(h.presenter.held.otherAlertCount(listing: isListed) == 2)

        let library = h.showLibrary()

        // The acknowledgement nobody dismissed comes back first, in the order
        // it was raised, and the one waiting behind it follows it there.
        #expect(sheetText(on: library).contains("Shown Notice"))
        #expect(h.presenter.waitingCountForTesting == 1)
        #expect(h.dismissShownAlert(.alertFirstButtonReturn))
        #expect(sheetText(on: library).contains("Waiting Notice"))
    }

    @Test("A display window closing answers a suspended verb's question unasked and cancels any other")
    func closingADisplayWindowEndsItsQuestions() throws {
        let h = makeHarness()
        let vm = makeRunningInstance(name: "Work", in: h.viewModel)
        let display = try showDisplayWindow(for: vm, in: h)
        let answers = Box<[PresenterAnswer<Bool>]>([])
        h.presenter.presentConfirmationRequest(
            ConfirmationRequest(
                instance: vm,
                prompt: ConfirmationPrompt(
                    kind: .startBesideSharedMachineIdentity, title: "Start Anyway?", message: "Twin.",
                    confirmTitle: "Start Anyway", dismissTitle: "Cancel"),
                answer: { answers.value.append($0) }))
        #expect(display.attachedSheet != nil)

        display.close()

        #expect(answers.value == [.unasked])
        #expect(h.presenter.waitingCountForTesting == 0)
        #expect(h.presenter.held.alerts.isEmpty)

        let other = makeRunningInstance(name: "Other", in: h.viewModel)
        let otherDisplay = try showDisplayWindow(for: other, in: h)
        h.presenter.presentForceStop(for: other)
        #expect(otherDisplay.attachedSheet != nil)

        otherDisplay.close()

        // Nothing runs without a yes, and the question is neither queued
        // nor held for another window.
        #expect(other.status == .running)
        #expect(h.presenter.waitingCountForTesting == 0)
        #expect(h.presenter.held.alerts.isEmpty)
    }

    @Test("With the library window closed and the VM headless, an alert is held, counted, and shown with the library")
    func heldAlertsWaitForTheLibrary() {
        let h = makeHarness()
        let vm = h.viewModel.library.admitFixture(name: "Headless")
        let isListed: (UUID) -> Bool = { id in h.viewModel.instances.contains { $0.id == id } }

        h.presenter.presentStartFailure("No disk.", title: "Couldn\u{2019}t Start", for: vm)
        h.presenter.presentError("A notice.", title: "Library Notice", about: .library)

        #expect(h.presenter.held.undoneStartCount(listing: isListed) == 1)
        #expect(h.presenter.held.otherAlertCount(listing: isListed) == 1)

        let library = h.showLibrary()

        #expect(sheetText(on: library).contains("Couldn\u{2019}t Start"))
        #expect(h.presenter.held.alerts.isEmpty)
        #expect(h.presenter.waitingCountForTesting == 1)
    }

    @Test("An alert about a VM that left the library is dropped, and stops counting as held")
    func alertAboutAVMThatLeftIsDropped() {
        let h = makeHarness()
        let vm = h.viewModel.library.admitFixture(name: "Leaving")
        let isListed: (UUID) -> Bool = { id in h.viewModel.instances.contains { $0.id == id } }
        h.presenter.presentStartFailure("No disk.", title: "Couldn\u{2019}t Start", for: vm)
        h.presenter.presentError("A notice.", title: "VM Notice", about: .vm(vm))

        h.viewModel.library.evict(vm)

        #expect(h.presenter.held.undoneStartCount(listing: isListed) == 0)
        #expect(h.presenter.held.otherAlertCount(listing: isListed) == 0)
        let library = h.showLibrary()
        #expect(library.attachedSheet == nil)
        #expect(h.presenter.waitingCountForTesting == 0)
    }

    @Test("A Force Stop whose VM stopped while it waited is dropped")
    func forceStopForAStoppedVMIsDropped() {
        let h = makeHarness()
        h.showLibrary()
        let vm = makeRunningInstance(name: "Work", in: h.viewModel)
        h.presenter.presentError("Busy.", title: "Library Notice", about: .library)
        h.presenter.presentForceStop(for: vm)
        #expect(h.presenter.waitingCountForTesting == 1)

        vm.activity.placeForTesting(.stopped)
        #expect(h.dismissShownAlert(.alertFirstButtonReturn))

        #expect(!h.isShowingAlert)
        #expect(h.presenter.waitingCountForTesting == 0)
    }

    @Test("A held launch account drops the VMs that left the library, and shows nothing once none is left")
    func heldLaunchAccountFollowsTheLibrary() {
        let h = makeHarness()
        let leaving = h.viewModel.library.admitFixture(name: "Leaving")
        let staying = h.viewModel.library.admitFixture(name: "Staying")
        let isListed: (UUID) -> Bool = { id in h.viewModel.instances.contains { $0.id == id } }
        let undone = [leaving, staying].map {
            let summary = $0.summary(ipAddress: .unavailable)
            return VMGroupActionResult(
                vm: summary, outcome: .failed(error: .busy(vm: summary, operation: "saving")))
        }
        h.presenter.presentStartSummary(title: "Launch Account", undone: undone)
        #expect(h.presenter.held.undoneStartCount(listing: isListed) == 2)

        h.viewModel.library.evict(leaving)

        #expect(h.presenter.held.undoneStartCount(listing: isListed) == 1)
        let library = h.showLibrary()
        let text = sheetText(on: library).joined(separator: "\n")
        #expect(text.contains("Staying"))
        #expect(!text.contains("Leaving"))

        #expect(h.dismissShownAlert(.alertFirstButtonReturn))
        h.presenter.presentStartSummary(title: "Launch Account", undone: [undone[0]])
        #expect(!h.isShowingAlert)
        #expect(h.presenter.waitingCountForTesting == 0)
    }

    @Test("While another sheet holds the window, an alert waits, and shows once that sheet ends")
    func anotherSheetHoldsTheWindow() {
        let h = makeHarness()
        let library = h.showLibrary()
        let foreign = makeTestWindow(styleMask: [.titled])
        library.beginSheet(foreign)

        h.presenter.presentError("Later.", title: "Waiting Notice", about: .library)

        #expect(library.attachedSheet === foreign)
        #expect(h.presenter.waitingCountForTesting == 1)
        #expect(h.presenter.held.alerts.isEmpty)

        library.endSheet(foreign)

        #expect(sheetText(on: library).contains("Waiting Notice"))
        #expect(h.presenter.waitingCountForTesting == 0)
    }

    // MARK: - Where a held alert shows

    /// Answers the placement controller with a fixed posture, standing in for
    /// the residency controller that reads the live one.
    private final class StubResidency: WindowResidencyHosting {
        let guiPosture: GUIPosture

        init(posture: GUIPosture) { guiPosture = posture }

        func prepareToPresentWindow() {}
        func syncActivationPolicy() {}
    }

    @Test("A held removal offer, shown when the library window appears, still offers the removal and runs it")
    func heldRemovalOfferKeepsItsRecovery() async throws {
        let h = makeHarness()
        let item = RemovableMediaItem(path: "/tmp/stale-\(UUID().uuidString).iso", readOnly: true, label: "Stale ISO")
        let vm = h.viewModel.library.admitFixture(name: "Stale") { $0.removableMedia = [item] }
        let failure = StartFailedAttachment(
            verb: .start, kind: .removableMedia, reason: .notFound, id: item.id, label: "Stale ISO",
            message: "The file isn\u{2019}t there.")

        h.presenter.presentStartFailedAttachment(failure, for: vm)
        #expect(h.presenter.held.alerts == [.startReport(vmIDs: [vm.id])])

        let library = h.showLibrary()

        #expect(sheetText(on: library).contains("Remove and Start"))
        #expect(h.presenter.held.alerts.isEmpty)
        #expect(h.dismissShownAlert(.alertFirstButtonReturn))
        try await waitForChange { vm.configuration.removableMedia?.isEmpty ?? true }
        try await vm.waitUntilIdle()
    }

    @Test("A held alert about a VM is shown when its display window is readied behind")
    func heldAlertShowsOnADisplayWindowReadiedBehind() throws {
        let h = makeHarness()
        let residency = StubResidency(posture: .background)
        h.registry.residency = residency
        let vm = h.viewModel.library.admitFixture(
            name: "Readied", phase: .running(sessionID: UUID()),
            hostState: VMHostState(displayPreference: .popOut))
        h.presenter.presentError("A notice.", title: "VM Notice", about: .vm(vm))
        #expect(h.presenter.held.alerts == [.other(vmID: vm.id)])

        h.registry.displayPlacement.readyDisplay(for: vm, presence: .unattended)

        let display = try #require(h.registry.displayPlacement.window(for: vm.id))
        #expect(sheetText(on: display).contains("VM Notice"))
        #expect(h.presenter.held.alerts.isEmpty)
        withExtendedLifetime(residency) {}
    }

    @Test("Closing the library window under the creation wizard holds the alert waiting behind it")
    func closingTheLibraryUnderTheWizardHoldsItsAlert() throws {
        let h = makeHarness()
        let library = h.showLibrary()
        let detail = try #require(h.registry.libraryDetailContainer)
        detail.presentCreationWizard()
        #expect(library.attachedSheet != nil)
        h.presenter.presentError("Later.", title: "Library Notice", about: .library)
        #expect(h.presenter.waitingCountForTesting == 1)

        h.closeLibrary()

        // The wizard ending under the closing window frees it while it still
        // reads as visible; the alert must not go up on it.
        #expect(!sheetText(on: library).contains("Library Notice"))
        #expect(h.presenter.waitingCountForTesting == 1)
        #expect(h.presenter.held.alerts == [.other(vmID: nil)])
    }
}
