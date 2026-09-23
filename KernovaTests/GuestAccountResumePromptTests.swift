import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the GUI's Start does about the account a macOS VM still owes a
/// password: when the verb refuses and the sheet goes up, what each of the
/// three answers carries back into the re-issued start, and what a start that
/// never reached a boot leaves behind.
@Suite("Guest Account Resume Prompt", .serialized, .admissionGated)
@MainActor
struct GuestAccountResumePromptTests {
    private let presenter = MockVMLibraryPresenting()
    private let preferences = makeTestPreferences()

    private func makeViewModel() -> (
        VMLibraryViewModel, MockVMStorageService, MockVirtualizationService
    ) {
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
        viewModel.presenter = presenter
        return (viewModel, storage, virtualization)
    }

    private func makeIntent() -> GuestAccountIntent {
        GuestAccountIntent(
            fullName: "Ada Lovelace", username: "ada", logsInAutomatically: true,
            enablesRemoteLogin: false)
    }

    /// A macOS VM carrying `intent`, resting where `phase` names — `.initialBoot`
    /// with an install still to run, or `.stopped` with nothing between the
    /// start and the boot.
    private func makeVM(
        in viewModel: VMLibraryViewModel, storage: MockVMStorageService,
        intent: GuestAccountIntent?, installPending: Bool = true,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(name: "Sequoia", guestOS: .macOS) {
            if installPending {
                $0.installContext = MacOSInstallContext(
                    source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
            }
            $0.pendingGuestAccount = intent
            mutate(&$0)
        }
        instance.enter(installPending ? .initialBoot : .stopped)
        viewModel.library.register(instance, storage: storage)
        return instance
    }

    /// Lets the install pipeline the start armed unwind, so nothing outlives the
    /// test that spawned it.
    private func drainSetup(_ instance: VMInstance) async {
        let task = instance.setupTask
        task?.cancel()
        await task?.value
    }

    // MARK: - When the question is raised

    @available(macOS 27.0, *)
    @Test("Starting a VM that owes an account asks for its password")
    func aStartAsksForThePassword() async throws {
        let (viewModel, storage, _) = makeViewModel()
        let instance = makeVM(in: viewModel, storage: storage, intent: makeIntent())

        await viewModel.start(instance)

        let request = try #require(presenter.guestAccountPasswordRequests.first)
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(request.prompt.vm.name == "Sequoia")
        #expect(request.prompt.vm.id == instance.id)
        #expect(request.prompt.username == "ada")
        #expect(request.prompt.fullName == "Ada Lovelace")
        #expect(request.prompt.message.contains("ada"))
        // The sheet is the question, not an error report.
        #expect(presenter.errors.isEmpty)
        await drainSetup(instance)
    }

    @Test("A VM whose install creates no account is started without a question")
    func aVMWithNoIntentIsNotAsked() async {
        let (viewModel, storage, _) = makeViewModel()
        let instance = makeVM(in: viewModel, storage: storage, intent: nil)

        await viewModel.start(instance)

        #expect(presenter.guestAccountPasswordRequests.isEmpty)
        #expect(instance.setupTask != nil)
        await drainSetup(instance)
    }

    @Test("A recovery boot asks nothing — it cannot spend the account anyway")
    func aRecoveryBootIsNotAsked() async {
        let (viewModel, storage, _) = makeViewModel()
        let instance = makeVM(in: viewModel, storage: storage, intent: makeIntent())

        await viewModel.start(instance, bootIntoRecovery: true)

        #expect(presenter.guestAccountPasswordRequests.isEmpty)
    }

    // MARK: - What each answer carries back

    @available(macOS 27.0, *)
    @Test("A supplied password reaches the boot the loop re-issues")
    func aSuppliedPasswordReachesTheBoot() async throws {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false)
        presenter.guestAccountPasswordAnswer = .password("analytical-engine")

        await viewModel.start(instance)

        let carried = try #require(virtualization.lastStartProvisioning)
        #expect(carried.password == "analytical-engine")
        // Rejoined with the persisted intent rather than gathered again.
        #expect(carried.username == "ada")
        #expect(carried.fullName == "Ada Lovelace")
        #expect(carried.logsInAutomatically)
        // Asked once, then answered and re-run.
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(presenter.errors.isEmpty)
        // The boot came up, so both halves of the account are spent.
        #expect(instance.configuration.pendingGuestAccount == nil)
    }

    @available(macOS 27.0, *)
    @Test("Skipping setup re-issues the start, which boots with no account")
    func skippingBootsWithoutTheAccount() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false)
        presenter.guestAccountPasswordAnswer = .skip

        await viewModel.start(instance)

        #expect(virtualization.lastStartProvisioning == nil)
        #expect(virtualization.startCallCount == 1)
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(presenter.errors.isEmpty)
        // Skipping is about the VM: it ends the account there and then.
        #expect(instance.configuration.pendingGuestAccount == nil)
    }

    @available(macOS 27.0, *)
    @Test("A skip whose boot failed does not put the question back on the next Start")
    func aSkipWhoseBootFailedDoesNotAskAgain() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false)
        virtualization.startError = VirtualizationError.noVirtualMachine
        presenter.guestAccountPasswordAnswer = .skip

        await viewModel.start(instance)
        #expect(instance.configuration.pendingGuestAccount == nil)

        await viewModel.start(instance)

        // The skip answered the VM rather than one call, so the second gesture
        // goes straight to the boot.
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(virtualization.startCallCount == 2)
    }

    @available(macOS 27.0, *)
    @Test("Cancelling the sheet starts nothing and says nothing")
    func cancellingStartsNothing() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(in: viewModel, storage: storage, intent: makeIntent())
        presenter.guestAccountPasswordAnswer = .cancelled

        await viewModel.start(instance)

        #expect(instance.setupTask == nil)
        #expect(virtualization.startCallCount == 0)
        // Walking away from a question is not a failure worth an alert.
        #expect(presenter.errors.isEmpty)
        // Still asked for next time, from the same untouched intent.
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
        #expect(viewModel.capabilities.owesGuestAccountAnswer(instance))
    }

    /// The shown sheet turns a refused password down on the click and puts
    /// itself back up carrying the reason (`GuestAccountPasswordAlertTests`), so
    /// what reaches here is a door with no validator of its own: the verb refuses
    /// and the start never runs.
    @available(macOS 27.0, *)
    @Test("A password macOS turns down never reaches a boot")
    func aRefusedPasswordNeverReachesTheBoot() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false)
        presenter.guestAccountPasswordAnswer = .password("a")

        await viewModel.start(instance)

        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(virtualization.startCallCount == 0)
        #expect(!presenter.errors.isEmpty)
        // Nothing held and nothing spent, so the next Start asks again.
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
        #expect(viewModel.capabilities.owesGuestAccountAnswer(instance))
    }

    // MARK: - A start that never reached a boot

    @available(macOS 27.0, *)
    @Test("A failed boot keeps the answer, so the next start asks nothing")
    func aFailedBootKeepsTheAnswer() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false)
        virtualization.startError = VirtualizationError.noVirtualMachine
        presenter.guestAccountPasswordAnswer = .password("analytical-engine")

        await viewModel.start(instance)

        // The boot threw before the guest ran, so the window is unspent — and the
        // answer supplied for it is still held.
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
        #expect(!viewModel.capabilities.owesGuestAccountAnswer(instance))
        #expect(presenter.guestAccountPasswordRequests.count == 1)

        virtualization.startError = nil
        await viewModel.start(instance)

        // The retry carries what was typed the first time, with nothing asked.
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(virtualization.lastStartProvisioning?.password == "analytical-engine")
    }

    @available(macOS 27.0, *)
    @Test("The start-failed recovery removes, then runs the ordinary Start that asks")
    func theStartFailedRecoveryAsksThroughTheOrdinaryStart() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let disk = StorageDisk(path: "/tmp/missing.img", label: "Scratch", isInternal: false)
        let keeper = StorageDisk(
            path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false
        ) { $0.storageDisks = [disk, keeper] }
        presenter.guestAccountPasswordAnswer = .password("analytical-engine")

        await viewModel.removeStartFailedAttachmentAndStart(
            StartFailedAttachment(
                verb: .start, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                label: "Scratch",
                message: "It would not open."),
            on: instance)

        // The removal happened once, and the account was asked for once — by the
        // ordinary Start that followed it, not by a compound verb re-issued whole.
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(virtualization.lastStartProvisioning?.password == "analytical-engine")
        #expect(presenter.errors.isEmpty)
    }

    @available(macOS 27.0, *)
    @Test("A start-failed recovery whose removal refuses starts nothing")
    func aRefusedRecoveryRemovalStartsNothing() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let sole = StorageDisk(path: "/tmp/missing.img", label: "Scratch", isInternal: false)
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false
        ) { $0.storageDisks = [sole] }
        presenter.guestAccountPasswordAnswer = .password("analytical-engine")

        // A VM keeps at least one storage disk, so the removal is refused.
        await viewModel.removeStartFailedAttachmentAndStart(
            StartFailedAttachment(
                verb: .start, kind: .storageDisk, reason: .attachRefused, id: sole.id,
                label: "Scratch",
                message: "It would not open."),
            on: instance)

        #expect(instance.configuration.storageDisks?.map(\.id) == [sole.id])
        #expect(virtualization.startCallCount == 0)
        // The attachment is still attached, so the refusal is what the user sees
        // rather than an account question about a start that cannot happen.
        #expect(!presenter.errors.isEmpty)
        #expect(presenter.guestAccountPasswordRequests.isEmpty)
    }

    @available(macOS 27.0, *)
    @Test("A start-failed recovery for a VM that left the library starts nothing")
    func aRecoveryForADepartedVMStartsNothing() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(in: viewModel, storage: storage, intent: makeIntent())
        viewModel.instances.removeAll()

        await viewModel.removeStartFailedAttachmentAndStart(
            StartFailedAttachment(
                verb: .start, kind: .storageDisk, reason: .attachRefused, id: UUID(),
                label: "Scratch",
                message: "It would not open."),
            on: instance)

        // Neither half runs, and a VM the user deleted is nothing to read an
        // alert about.
        #expect(virtualization.startCallCount == 0)
        #expect(presenter.guestAccountPasswordRequests.isEmpty)
        #expect(presenter.errors.isEmpty)
    }

    @available(macOS 27.0, *)
    @Test("With no window to ask in, the refusal takes the ordinary error surface")
    func noPresenterSurfacesTheRefusal() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(in: viewModel, storage: storage, intent: makeIntent())
        viewModel.presenter = nil

        await viewModel.start(instance)

        #expect(virtualization.startCallCount == 0)
        #expect(instance.setupTask == nil)
        // Buffered for the window that eventually appears, and the account is
        // still there to ask about when it does.
        #expect(instance.configuration.pendingGuestAccount == makeIntent())

        viewModel.presenter = presenter
        #expect(presenter.errors.contains { $0.contains("ada") })
        #expect(presenter.guestAccountPasswordRequests.isEmpty)
    }
}
