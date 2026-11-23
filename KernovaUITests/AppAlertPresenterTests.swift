import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers `AppAlertPresenter` against the app's real windows: the library
/// window a ``Harness`` shows and closes. A window closed under the presenter
/// is how a test takes the surface away; a sheet ended with a button's return
/// code is how it clicks.
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
        let focus = RecordingSessionFocus()
        let storage = MockVMStorageService()
        let fileSystem = MockFileSystem()

        init(preferences: AppPreferences) {
            viewModel = makeLibraryViewModel(
                preferences: preferences, storageService: storage, fileSystem: fileSystem)
            registry = makeWindowRegistry(viewModel, focus: focus)
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

    // MARK: - A confirmation a verb waits on

    private func confirmationRequest(
        answers: Box<[PresenterAnswer<ConfirmationAnswer>]>, offersDontAskAgain: Bool = false
    ) -> ConfirmationRequest {
        ConfirmationRequest(
            instance: VMInstanceFixture.make(name: "Twin"),
            prompt: ConfirmationPrompt(
                kind: .startBesideSharedMachineIdentity,
                title: "Start \u{201C}Twin\u{201D} with a Duplicate Machine ID?",
                message: "\u{201C}Twin\u{201D} has the same machine ID as \u{201C}Live\u{201D}, which is active.",
                confirmTitle: "Start", dismissTitle: "Cancel"),
            offersDontAskAgain: offersDontAskAgain,
            answer: { answers.value.append($0) })
    }

    /// The checkbox titled `title` on the library window's sheet.
    private func sheetCheckbox(titled title: String, in h: Harness) -> NSButton? {
        func find(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find(in:)).first
        }
        return h.registry.libraryWindow?.attachedSheet?.contentView.flatMap(find(in:))
    }

    /// The answers a question offering Don't ask again gives, by whether the
    /// box is ticked and which button ends it.
    nonisolated static let dontAskAgainCases: [(ticked: Bool, button: Int, answer: ConfirmationAnswer)] = [
        (true, 0, .confirm(dontAskAgain: true)),
        (false, 0, .confirm(dontAskAgain: false)),
        // Cancel saves nothing, ticked or not.
        (true, 1, .decline),
    ]

    @Test(
        "A question offering Don't ask again draws the alert's suppression checkbox, whose state comes back only with a confirm",
        arguments: dontAskAgainCases.indices)
    func dontAskAgainAnswersWithTheConfirm(index: Int) throws {
        let row = Self.dontAskAgainCases[index]
        let h = makeHarness()
        h.showLibrary()
        let answers = Box<[PresenterAnswer<ConfirmationAnswer>]>([])

        h.presenter.presentConfirmationRequest(confirmationRequest(answers: answers, offersDontAskAgain: true))
        let box = try #require(sheetCheckbox(titled: "Don\u{2019}t ask again", in: h))
        #expect(box.state == .off)
        if row.ticked { box.state = .on }
        #expect(
            h.dismissShownAlert(
                NSApplication.ModalResponse(
                    rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + row.button)))
        h.closeLibrary()

        #expect(answers.value == [.answered(row.answer)])
    }

    /// Holds what the requests under test are answered with.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
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
}
