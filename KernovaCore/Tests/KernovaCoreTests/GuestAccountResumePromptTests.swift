import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What the GUI's Start does about the account a macOS VM still owes a
/// password: when the verb refuses and the sheet goes up, what each of the
/// three answers carries back into the re-issued start, and what a start that
/// never reached a boot leaves behind.
@Suite("Guest Account Resume Prompt", .serialized, .caseScoped)
@MainActor
struct GuestAccountResumePromptTests {
    private let presenter = MockVMLibraryPresenting()
    private let preferences = makeTestPreferences()

    private func makeViewModel(
        host: FakeVirtualizationHost = FakeVirtualizationHost()
    ) -> (VMLibraryViewModel, MockVirtualizationService) {
        let virtualization = MockVirtualizationService()
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: host,
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: MockLocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: MockBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
        )
        viewModel.presenter = presenter
        return (viewModel, virtualization)
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
        in viewModel: VMLibraryViewModel, intent: GuestAccountIntent?, installPending: Bool = true,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = viewModel.library.registerFixture(name: "Sequoia", guestOS: .macOS) {
            if installPending {
                $0.installContext = MacOSInstallContext(
                    source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
            }
            $0.pendingGuestAccount = intent
            mutate(&$0)
        }
        instance.activity.placeForTesting(installPending ? .initialBoot : .stopped)
        return instance
    }

    /// Lets the install pipeline the start armed unwind, so nothing outlives the
    /// test that spawned it.
    private func drainSetup(_ instance: VMInstance) async {
        let task = instance.setupOperationTask
        task?.cancel()
        await task?.value
    }

    // MARK: - When the question is raised

    // MARK: - What each answer carries back

    @available(macOS 27.0, *)
    @Test("A supplied password reaches the boot the loop re-issues")
    func aSuppliedPasswordReachesTheBoot() async throws {
        let (viewModel, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, intent: makeIntent(), installPending: false)
        presenter.guestAccountPasswordAnswer = .answered(.password("analytical-engine"))

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
        let (viewModel, virtualization) = makeViewModel()
        let instance = makeVM(
            in: viewModel, intent: makeIntent(), installPending: false)
        presenter.guestAccountPasswordAnswer = .answered(.skip)

        await viewModel.start(instance)

        #expect(virtualization.lastStartProvisioning == nil)
        #expect(virtualization.startCallCount == 1)
        #expect(presenter.guestAccountPasswordRequests.count == 1)
        #expect(presenter.errors.isEmpty)
        // Skipping is about the VM: it ends the account there and then.
        #expect(instance.configuration.pendingGuestAccount == nil)
    }

    @available(macOS 27.0, *)
    @Test("Cancelling the sheet starts nothing and says nothing")
    func cancellingStartsNothing() async {
        let (viewModel, virtualization) = makeViewModel()
        let instance = makeVM(in: viewModel, intent: makeIntent())
        presenter.guestAccountPasswordAnswer = .answered(.cancelled)

        await viewModel.start(instance)

        #expect(instance.setupOperationTask == nil)
        #expect(virtualization.startCallCount == 0)
        // Walking away from a question is not a failure worth an alert.
        #expect(presenter.errors.isEmpty)
        // Still asked for next time, from the same untouched intent.
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
        #expect(viewModel.capabilities.guestAccountState(of: instance).isOwed)
    }

    @available(macOS 27.0, *)
    @Test("A sheet that could not be shown leaves the account refusal standing, shown as an error")
    func anUnaskedSheetShowsTheRefusal() async {
        let (viewModel, virtualization) = makeViewModel()
        let instance = makeVM(in: viewModel, intent: makeIntent())
        presenter.guestAccountPasswordAnswer = .unasked

        await viewModel.start(instance)

        #expect(virtualization.startCallCount == 0)
        #expect(presenter.errorTitles == ["Couldn\u{2019}t Start \u{201C}\(instance.name)\u{201D}"])
        #expect(instance.configuration.pendingGuestAccount == makeIntent())
        #expect(instance.setupOperationTask == nil)
        #expect(presenter.errors.contains { $0.contains("ada") })
    }

    // MARK: - A start that never reached a boot

    @available(macOS 27.0, *)
    @Test("A start-failed recovery whose removal refuses starts nothing")
    func aRefusedRecoveryRemovalStartsNothing() async {
        let (viewModel, virtualization) = makeViewModel()
        let sole = StorageDisk(path: "/tmp/missing.img", label: "Scratch", isInternal: false)
        let instance = makeVM(
            in: viewModel, intent: makeIntent(), installPending: false
        ) { $0.storageDisks = [sole] }
        presenter.guestAccountPasswordAnswer = .answered(.password("analytical-engine"))

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
        let (viewModel, virtualization) = makeViewModel()
        let instance = makeVM(in: viewModel, intent: makeIntent())
        viewModel.library.evict(instance)

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
}
