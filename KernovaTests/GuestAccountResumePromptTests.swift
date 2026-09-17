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
    private let preferences = makeEphemeralPreferences(
        suiteName: "test.kernova.guestaccountresume")

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
            preferences: preferences
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
        intent: GuestAccountIntent?, installPending: Bool = true
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(name: "Sequoia", guestOS: .macOS) {
            if installPending {
                $0.installContext = MacOSInstallContext(
                    source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
            }
            $0.pendingGuestAccount = intent
        }
        instance.onUpdateConfiguration = { mutate in
            mutate(&instance.configuration)
            return true
        }
        instance.enter(installPending ? .initialBoot : .stopped)
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration
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
        presenter.guestAccountPasswordAnswer = .answered(.password("analytical-engine"))

        await viewModel.start(instance)

        let carried = try #require(virtualization.lastStartProvisioning)
        #expect(carried.password == "analytical-engine")
        // Rejoined with the persisted intent rather than gathered again.
        #expect(carried.username == "ada")
        #expect(carried.fullName == "Ada Lovelace")
        #expect(carried.logsInAutomatically)
        // Nothing asked twice, and nothing retracted here: the boot that
        // carried the account is what spends it.
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(presenter.errors.isEmpty)
    }

    @available(macOS 27.0, *)
    @Test("Skipping setup re-issues the start, which boots with no account")
    func skippingBootsWithoutTheAccount() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false)
        presenter.guestAccountPasswordAnswer = .answered(.skip)

        await viewModel.start(instance)

        #expect(virtualization.lastStartProvisioning == nil)
        #expect(virtualization.startCallCount == 1)
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(presenter.errors.isEmpty)
        // Skipping answers the call, not the VM: the account is ended by the
        // boot that comes up, which this harness stands in for.
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
    }

    @available(macOS 27.0, *)
    @Test("A skip whose boot failed puts the question back on the next Start")
    func aSkipWhoseBootFailedAsksAgain() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false)
        virtualization.startError = VirtualizationError.noVirtualMachine
        presenter.guestAccountPasswordAnswer = .answered(.skip)

        await viewModel.start(instance)
        #expect(instance.configuration.pendingGuestAccount == makeIntent())

        await viewModel.start(instance)

        // Nothing booted, so nothing was spent — and the second gesture is
        // asked exactly as the first was.
        #expect(presenter.guestAccountPasswordRequests.count == 2)
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
        #expect(instance.startAsksForGuestAccount)
    }

    // MARK: - A start that never reached a boot

    @available(macOS 27.0, *)
    @Test("A failed boot leaves the account in place, so the next start asks again")
    func aFailedBootKeepsTheAccount() async {
        let (viewModel, storage, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, storage: storage, intent: makeIntent(), installPending: false)
        virtualization.startError = VirtualizationError.noVirtualMachine
        presenter.guestAccountPasswordAnswer = .answered(.password("analytical-engine"))

        await viewModel.start(instance)

        // The boot threw before the guest ran, so the window is unspent.
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
        #expect(instance.startAsksForGuestAccount)
        #expect(presenter.guestAccountPasswordRequests.count == 1)

        // And the next start puts the question back up.
        await viewModel.start(instance)
        #expect(presenter.guestAccountPasswordRequests.count == 2)
    }

    @available(macOS 27.0, *)
    @Test("Removing a failed start's attachment asks before starting again")
    func theStartFailedRetryAsksToo() async {
        let (viewModel, storage, _) = makeViewModel()
        let instance = makeVM(in: viewModel, storage: storage, intent: makeIntent())
        presenter.guestAccountPasswordAnswer = .cancelled

        await viewModel.removeStartFailedAttachmentAndStart(
            StartFailedAttachment(
                kind: .storageDisk, id: UUID(), label: "Scratch", message: "It would not open."),
            on: instance)

        // Every door into a start runs the same loop: this one leads to the
        // same core start, which refuses one nobody answered for.
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(instance.setupTask == nil)
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
