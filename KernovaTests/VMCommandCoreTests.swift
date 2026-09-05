import Foundation
import KernovaKit
import Testing
import Virtualization

@testable import Kernova

/// The command core, driven with no view model and no presenter anywhere in
/// sight: every verb's happy and refused paths, selector resolution, the state
/// gates, and the consent refusals with the payload each carries.
@Suite("VMCommandCore Tests", .serialized, .admissionGated)
@MainActor
struct VMCommandCoreTests {
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.commandcore")

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let lifecycle: VMLifecycleCoordinator
        let storage: MockVMStorageService
        let virtualization: MockVirtualizationService
        let snapshots: MockVMSnapshotStore
        let fileSystem: MockFileSystem
        let vmnet: MockVmnetNetworkProvider
    }

    private func makeHarness(
        virtualization: MockVirtualizationService = MockVirtualizationService(),
        diskImages: MockDiskImageService = MockDiskImageService()
    ) -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMSnapshotStore()
        let fileSystem = MockFileSystem()
        let vmnet = MockVmnetNetworkProvider()
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            linuxImageResolveService: MockLinuxImageResolveService(),
            downloadService: MockDownloadService(),
            fileSystem: fileSystem
        )
        let library = VMLibrary(
            storageService: storage,
            snapshotStore: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: vmnet,
            isVMNetworkingEntitled: true
        )
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            snapshotStore: snapshots,
            diskImageService: diskImages,
            fileSystem: fileSystem,
            preferences: preferences
        )
        return Harness(
            core: core, library: library, lifecycle: lifecycle, storage: storage,
            virtualization: virtualization, snapshots: snapshots, fileSystem: fileSystem,
            vmnet: vmnet)
    }

    private struct SuspendingHarness {
        let core: VMCommandCore
        let library: VMLibrary
        let storage: MockVMStorageService
        let virtualization: SuspendingMockVirtualizationService
        let snapshots: MockVMSnapshotStore
    }

    /// A core whose virtualization service holds one operation suspended, so a
    /// test can look at the world while a VZ call is still in flight.
    private func makeSuspendingHarness() -> SuspendingHarness {
        let storage = MockVMStorageService()
        let snapshots = MockVMSnapshotStore()
        let fileSystem = MockFileSystem()
        let virtualization = SuspendingMockVirtualizationService()
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            linuxImageResolveService: MockLinuxImageResolveService(),
            downloadService: MockDownloadService(),
            fileSystem: fileSystem
        )
        let library = VMLibrary(
            storageService: storage,
            snapshotStore: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(),
            isVMNetworkingEntitled: true
        )
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            snapshotStore: snapshots,
            diskImageService: MockDiskImageService(),
            fileSystem: fileSystem,
            preferences: preferences
        )
        return SuspendingHarness(
            core: core, library: library, storage: storage, virtualization: virtualization,
            snapshots: snapshots)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Core VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, library: harness.library,
            storage: harness.storage, preferences: preferences)
    }

    @discardableResult
    private func makeInstance(
        in harness: SuspendingHarness, name: String = "Core VM",
        phase: VMLifecyclePhase = .stopped, snapshots: [VMSnapshot] = []
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: .linux, snapshots: snapshots,
            library: harness.library, storage: harness.storage, preferences: preferences)
    }

    private func commandError(_ body: () async throws -> Void) async -> CommandError? {
        do {
            try await body()
            return nil
        } catch let error as CommandError {
            return error
        } catch {
            return nil
        }
    }

    private func commandError(_ body: () throws -> Void) -> CommandError? {
        do {
            try body()
            return nil
        } catch let error as CommandError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - Selector resolution

    @Test("An identifier selector resolves the VM holding it")
    func resolvesByID() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha")

        #expect(try harness.core.info(.id(instance.id)).name == "Alpha")
    }

    @Test("A name selector matches exactly and case-sensitively")
    func resolvesByName() throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "Alpha")

        #expect(try harness.core.info(.name("Alpha")).name == "Alpha")
        #expect(commandError { _ = try harness.core.info(.name("alpha")) }?.isNotFound == true)
    }

    @Test("Text is read as an identifier first, then as a name")
    func resolvesIDOrName() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha")

        #expect(try harness.core.info(.idOrName(instance.id.uuidString)).name == "Alpha")
        #expect(try harness.core.info(.idOrName("Alpha")).name == "Alpha")
        // A UUID nothing answers to falls back to the name lookup rather than
        // stopping at the identifier.
        #expect(
            commandError { _ = try harness.core.info(.idOrName(UUID().uuidString)) }?.isNotFound
                == true)
    }

    @Test("An unmatched selector refuses as not found")
    func notFound() {
        let harness = makeHarness()

        #expect(commandError { _ = try harness.core.info(.name("Nothing")) }?.isNotFound == true)
    }

    @Test("A name two VMs answer to refuses with both candidates")
    func ambiguousCarriesEveryCandidate() throws {
        let harness = makeHarness()
        let first = makeInstance(in: harness, name: "Twin")
        let second = makeInstance(in: harness, name: "Twin", phase: .running(sessionID: UUID()))

        let error = try #require(commandError { _ = try harness.core.info(.name("Twin")) })
        guard case .ambiguous(let selector, let candidates) = error else {
            Issue.record("expected an ambiguity refusal, got \(error)")
            return
        }
        #expect(selector == .name("Twin"))
        #expect(candidates.map(\.id) == [first.id, second.id])
        #expect(candidates.map(\.status) == ["stopped", "running"])
    }

    // MARK: - Reads

    @Test("list answers every VM in library order")
    func listsInLibraryOrder() {
        let harness = makeHarness()
        makeInstance(in: harness, name: "First")
        makeInstance(in: harness, name: "Second", phase: .running(sessionID: UUID()))

        #expect(harness.core.list().map(\.name) == ["First", "Second"])
        #expect(harness.core.list().map(\.status) == ["stopped", "running"])
    }

    @Test("info reports the VM's shape and status")
    func infoReportsTheVM() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Described")
        instance.configuration.cpuCount = 6

        let info = try harness.core.info(.id(instance.id))

        #expect(info.name == "Described")
        #expect(info.status == "stopped")
        #expect(info.guestOS == "linux")
        #expect(info.cpuCount == 6)
        #expect(info.snapshotCount == 0)
        // Networking is off on the fixture, so there is no address to report.
        #expect(info.ipAddress == nil)
        #expect(info.networkMode == nil)
    }

    @Test("A stopped VM's reserved address answers info and the ip verb alike")
    func theReservedAddressAnswersEveryHeadlessRead() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Addressed")
        // Through the declaration path, which is what claims the slot the
        // address derives from — no surface reserves one by reading.
        harness.library.updateConfiguration(of: instance) {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "aa:bb:cc:dd:ee:01"
        }
        #expect(harness.vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:01"])

        // Nothing derives an address until the network's addressing is known,
        // and no headless read invents one meanwhile.
        #expect(try harness.core.info(.id(instance.id)).ipAddress == nil)
        #expect(try harness.core.ipAddress(of: .id(instance.id)) == nil)

        harness.vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:01": "192.168.64.4"]

        #expect(try harness.core.info(.id(instance.id)).ipAddress == "192.168.64.4")
        #expect(try harness.core.ipAddress(of: .id(instance.id)) == "192.168.64.4")
    }

    @Test("snapshots answers the manifest newest first")
    func snapshotsAreNewestFirst() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let older = VMSnapshot(name: "Older", createdAt: Date(timeIntervalSince1970: 1))
        let newer = VMSnapshot(name: "Newer", createdAt: Date(timeIntervalSince1970: 2))
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [older, newer], currentID: newer.id)

        let listed = try harness.core.snapshots(of: .id(instance.id))

        #expect(listed.map(\.name) == ["Newer", "Older"])
        #expect(listed.first?.isCurrent == true)
        #expect(listed.allSatisfy { !$0.isEphemeralBaseline })
    }

    // MARK: - Lifecycle happy paths

    @Test("start boots a stopped VM")
    func startBoots() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        try await harness.core.start(.id(instance.id), recovery: false)

        #expect(harness.virtualization.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("start surfaces the VM's display before it boots")
    func startSurfacesTheDisplay() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        var surfaced: [UUID] = []
        harness.core.surfaceDisplay = { surfaced.append($0.id) }

        try await harness.core.start(.id(instance.id), recovery: false)

        #expect(surfaced == [instance.id])
    }

    @Test("pause, resume, and suspend each reach the service")
    func pauseResumeSuspend() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        try await harness.core.pause(.id(instance.id))
        #expect(harness.virtualization.pauseCallCount == 1)

        try await harness.core.resume(.id(instance.id))
        #expect(harness.virtualization.resumeCallCount == 1)

        instance.enter(.running(sessionID: UUID()))
        try await harness.core.suspend(.id(instance.id))
        #expect(harness.virtualization.saveCallCount == 1)
    }

    @Test("A graceful stop of a running VM needs no confirmation")
    func gracefulStopRuns() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        try await harness.core.stop(.id(instance.id), disposition: .graceful, confirmed: false)

        #expect(harness.virtualization.stopCallCount == 1)
    }

    @Test("open brings the display of a VM that has one to the front")
    func openSurfacesTheDisplay() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        var surfaced: [UUID] = []
        harness.core.surfaceDisplay = { surfaced.append($0.id) }

        try harness.core.open(.id(instance.id))

        #expect(surfaced == [instance.id])
    }

    @Test("open refuses a VM with no display, naming the verbs it does accept")
    func openRefusesAStoppedVM() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        var surfaced = 0
        harness.core.surfaceDisplay = { _ in surfaced += 1 }

        let error = try #require(commandError { try harness.core.open(.id(instance.id)) })
        guard case .invalidState(let vm, let current, let allowed) = error else {
            Issue.record("expected an invalid-state refusal, got \(error)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(current == .stopped)
        #expect(allowed.contains(.start))
        #expect(!allowed.contains(.open))
        #expect(surfaced == 0)
    }

    @Test("open refuses a phantom whose bundle is still being copied")
    func openRefusesAPreparingVM() throws {
        let harness = makeHarness()
        // An imported bundle carrying a save file rests its phantom `.paused`,
        // which reads as having a display while the copy is still writing.
        let instance = makeInstance(in: harness, name: "Copying", phase: .suspended)
        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: Task {})
        var surfaced = 0
        harness.core.surfaceDisplay = { _ in surfaced += 1 }

        let error = try #require(commandError { try harness.core.open(.id(instance.id)) })

        #expect(error.isBusy)
        #expect(surfaced == 0)
        #expect(!harness.core.allowedVerbs(for: instance).contains(.open))
        instance.preparingState = nil
    }

    @Test("reveal surfaces the display of a VM that has one")
    func revealSurfacesTheDisplay() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        var surfaced: [UUID] = []
        var revealed: [UUID] = []
        harness.core.surfaceDisplay = { surfaced.append($0.id) }
        harness.core.revealInLibrary = { revealed.append($0.id) }

        try harness.core.reveal(.id(instance.id))

        #expect(surfaced == [instance.id])
        #expect(revealed.isEmpty)
    }

    @Test("reveal puts a VM with no display in the library instead of refusing")
    func revealFallsBackToTheLibrary() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        var surfaced: [UUID] = []
        var revealed: [UUID] = []
        harness.core.surfaceDisplay = { surfaced.append($0.id) }
        harness.core.revealInLibrary = { revealed.append($0.id) }

        try harness.core.reveal(.id(instance.id))

        #expect(revealed == [instance.id])
        #expect(surfaced.isEmpty)
    }

    @Test("reveal of a phantom still being copied lands on its library row")
    func revealOfAPreparingVMLandsInTheLibrary() throws {
        let harness = makeHarness()
        // The phantom of an import carrying a save file rests `.paused`, which
        // reads as having a display the copy has not finished writing.
        let instance = makeInstance(in: harness, name: "Copying", phase: .suspended)
        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: Task {})
        var surfaced: [UUID] = []
        var revealed: [UUID] = []
        harness.core.surfaceDisplay = { surfaced.append($0.id) }
        harness.core.revealInLibrary = { revealed.append($0.id) }

        try harness.core.reveal(.id(instance.id))

        #expect(revealed == [instance.id])
        #expect(surfaced.isEmpty)
        instance.preparingState = nil
    }

    @Test("reveal refuses a selector no VM answers to, as open does")
    func revealRefusesAnUnknownSelector() throws {
        let harness = makeHarness()
        var revealed = 0
        harness.core.revealInLibrary = { _ in revealed += 1 }

        let error = try #require(commandError { try harness.core.reveal(.name("Nowhere")) })

        #expect(error == .notFound(.name("Nowhere")))
        #expect(revealed == 0)
    }

    // MARK: - Allowed verbs

    @Test("allowedVerbs reads out in a fixed order, reads first")
    func allowedVerbsOrder() {
        let harness = makeHarness()
        let stopped = makeInstance(in: harness, name: "Stopped", phase: .stopped)

        // The order is user-visible: `invalidState` renders this list as
        // "What it accepts now: Start, Take Snapshot, …".
        #expect(
            harness.core.allowedVerbs(for: stopped) == [
                .info, .ipAddress, .snapshots, .start, .reveal, .takeSnapshot, .deleteSnapshot,
                .renameSnapshot, .setSnapshotNotes, .editStorageDisk, .editRemovableMedia,
                .editSharedDirectory, .clone, .rename, .delete,
            ])

        let running = makeInstance(
            in: harness, name: "Running", phase: .running(sessionID: UUID()))
        #expect(
            harness.core.allowedVerbs(for: running) == [
                .info, .ipAddress, .snapshots, .stop, .restart, .pause, .suspend, .open, .reveal,
                .takeSnapshot, .deleteSnapshot, .renameSnapshot, .setSnapshotNotes,
                .editRemovableMedia, .rename,
            ])
    }

    @Test("A cold-paused VM reports its saved-state discard as the one stop it takes")
    func allowedVerbsForAColdPausedVM() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .suspended)

        // No live VM to terminate and no graceful stop, but the discard rides
        // the same verb — named once, in the same slot.
        #expect(!instance.canStop)
        #expect(!instance.canForceStop)
        #expect(
            harness.core.allowedVerbs(for: instance) == [
                .info, .ipAddress, .snapshots, .stop, .resume, .open, .reveal, .deleteSnapshot,
                .renameSnapshot, .setSnapshotNotes, .rename, .delete,
            ])
    }

    @Test("A preparing VM reports its reads and the cancel that stops the copy")
    func allowedVerbsWhilePreparing() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: task)

        #expect(
            harness.core.allowedVerbs(for: instance) == [
                .info, .ipAddress, .snapshots, .reveal, .cancelPreparing,
            ])
    }

    // MARK: - State gates

    @Test("A suspended VM's stop passes the gate on discard-saved-state, not on stop")
    func suspendedStopIsAdmittedByTheDiscardCapability() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Suspended", phase: .suspended)

        // Nothing to shut down gracefully — the discard half of the stop slot's
        // pair is what admits this one.
        #expect(!harness.core.capabilities.accepts(.stop, on: instance))
        #expect(harness.core.capabilities.accepts(.discardSavedState, on: instance))

        try await harness.core.stop(.id(instance.id), disposition: .graceful, confirmed: true)
        #expect(harness.virtualization.stopCallCount == 1)
    }

    @Test("start refuses a VM that is already running")
    func startRefusesARunningVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        let error = try #require(
            await commandError { try await harness.core.start(.id(instance.id), recovery: false) })
        #expect(error.isInvalidState)
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A recovery boot is refused for a guest that has no recovery environment")
    func recoveryBootRefusedForLinux() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, guestOS: .linux)

        let error = try #require(
            await commandError { try await harness.core.start(.id(instance.id), recovery: true) })
        guard case .unsupported(let capability) = error else {
            Issue.record("expected an unsupported refusal, got \(error)")
            return
        }
        #expect(capability.contains("Recovery"))
    }

    @Test("pause refuses a stopped VM")
    func pauseRefusesAStoppedVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        let error = try #require(
            await commandError { try await harness.core.pause(.id(instance.id)) })
        #expect(error.isInvalidState)
        #expect(harness.virtualization.pauseCallCount == 0)
    }

    @Test("A verb refuses a VM whose clone or import is still copying")
    func refusesAPreparingVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.preparingState = VMInstance.PreparingState(
            operation: .importing, task: Task {})

        let error = try #require(
            await commandError { try await harness.core.start(.id(instance.id), recovery: false) })
        guard case .busy(let vm, let operation) = error else {
            Issue.record("expected a busy refusal, got \(error)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(operation == "import")
        instance.preparingState = nil
    }

    @Test("A state gate reached while preparing reports busy, not a self-contradictory invalid state")
    func invalidStateReportsBusyWhilePreparing() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Copying")
        instance.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: Task {})

        let error = try #require(await commandError { try await harness.core.pause(.id(instance.id)) })
        guard case .busy(let vm, let operation) = error else {
            Issue.record("expected a busy refusal, got \(error)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(operation == "clone")
        instance.preparingState = nil
    }

    @Test("resume refuses a VM whose clone or import is still copying")
    func resumeRefusesAPreparingVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Copying", phase: .suspended)
        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: Task {})

        let error = try #require(await commandError { try await harness.core.resume(.id(instance.id)) })
        #expect(error.isBusy)
        #expect(harness.virtualization.resumeCallCount == 0)
        instance.preparingState = nil
    }

    @Test("start refused mid-install names cancelGuestSetup as the way out")
    func startRefusedMidInstallNamesCancelGuestSetup() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .installing(sessionID: nil))
        instance.setupTask = Task {}

        let error = try #require(
            await commandError { try await harness.core.start(.id(instance.id), recovery: false) })
        guard case .invalidState(let vm, let current, let allowed) = error else {
            Issue.record("expected an invalid-state refusal, got \(error)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(current == .installing)
        #expect(allowed.contains(.cancelGuestSetup))
    }

    @Test("cancelGuestSetup without consent refuses with the confirmation naming the running step")
    func cancelGuestSetupWithoutConsentNamesTheStep() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .installing(sessionID: nil))
        instance.setupTask = Task {}
        instance.setupState = .macOSInstall(hasDownloadStep: true)

        let error = try #require(
            commandError { try harness.core.cancelGuestSetup(.id(instance.id), confirmed: false) })
        guard case .confirmationRequired(let prompt) = error else {
            Issue.record("expected a consent refusal, got \(error)")
            return
        }
        #expect(prompt.kind == .cancelGuestSetup)
        #expect(prompt.title == "Cancel Download?")
    }

    @Test("cancelGuestSetup's prompt names what a cancel costs at each step")
    func cancelGuestSetupPromptVariesByStep() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .installing(sessionID: nil))

        instance.setupState = .macOSInstall(hasDownloadStep: false)
        let install = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(install.title == "Cancel Installation?")
        #expect(install.confirmTitle == "Cancel Installation")
        #expect(install.dismissTitle == "Keep Installing")

        instance.setupState = .linuxImage(hasVerifyStep: true)
        instance.setupState?.advance(progress: .fraction(0))
        let verify = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(verify.title == "Cancel Verification?")
        #expect(verify.confirmTitle == "Cancel Verification")
        #expect(verify.dismissTitle == "Keep Verifying")

        instance.setupState = .macOSInstall(hasDownloadStep: true)
        let download = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(download.title == "Cancel Download?")
        #expect(download.confirmTitle == "Cancel Download")
        #expect(download.dismissTitle == "Keep Downloading")

        instance.setupState = nil
        let fallback = VMCommandCore.cancelGuestSetupPrompt(instance)
        #expect(fallback.title == "Cancel Download?")
        #expect(fallback.dismissTitle == "Keep Downloading")
    }

    @Test("A cancel accepted as the pipeline finishes stops the chained auto-boot")
    func cancelAtTheTailOfSetupDoesNotBoot() async throws {
        let storage = MockVMStorageService()
        let snapshots = MockVMSnapshotStore()
        let fileSystem = MockFileSystem()
        let virtualization = MockVirtualizationService()
        // Returns normally once released, so the pipeline succeeds *after* the
        // cancel lands — the window a `CancellationError` never reports.
        let installService = ReleasableMockMacOSInstallService()
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualization,
            installService: installService,
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            linuxImageResolveService: MockLinuxImageResolveService(),
            downloadService: MockDownloadService(),
            fileSystem: fileSystem
        )
        let library = VMLibrary(
            storageService: storage,
            snapshotStore: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(),
            isVMNetworkingEntitled: true
        )
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            snapshotStore: snapshots, diskImageService: MockDiskImageService(),
            fileSystem: fileSystem, preferences: preferences)

        var config = VMConfiguration(name: "Installing", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, phase: .initialBoot,
            preferences: preferences)
        library.wirePersistence(for: instance)
        library.instances.append(instance)
        storage.bundles[bundleURL] = config

        try await core.start(.id(instance.id), recovery: false)
        for await _ in installService.installStartedStream { break }

        try core.cancelGuestSetup(.id(instance.id), confirmed: true)
        installService.release()
        await instance.setupTask?.value

        #expect(virtualization.startCallCount == 0)
        #expect(instance.status == .initialBoot)
    }

    // MARK: - Conflicts

    @Test("A start that would put two live guests on one machine identity is refused")
    func duplicateMachineIDRefusesTheStart() async throws {
        let harness = makeHarness()
        preferences.blockDuplicateMachineIDBoot = true
        let identity = Data([1, 2, 3, 4])
        let live = makeInstance(in: harness, name: "Live", phase: .running(sessionID: UUID()))
        live.configuration.genericMachineIdentifierData = identity
        let twin = makeInstance(in: harness, name: "Twin")
        twin.configuration.genericMachineIdentifierData = identity

        let error = try #require(
            await commandError { try await harness.core.start(.id(twin.id), recovery: false) })
        guard case .conflict(let vm, let other, let reason) = error else {
            Issue.record("expected a conflict refusal, got \(error)")
            return
        }
        #expect(vm.id == twin.id)
        #expect(other.id == live.id)
        #expect(reason == .machineIdentity)
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("The same refusal fires on a cold resume, and not on a hot one")
    func duplicateMachineIDRefusesAColdResume() async throws {
        let harness = makeHarness()
        preferences.blockDuplicateMachineIDBoot = true
        let identity = Data([9, 9, 9])
        let live = makeInstance(in: harness, name: "Live", phase: .running(sessionID: UUID()))
        live.configuration.genericMachineIdentifierData = identity
        let twin = makeInstance(in: harness, name: "Twin", phase: .suspended)
        twin.configuration.genericMachineIdentifierData = identity

        // Cold-paused: the resume builds a fresh VM and claims the identity.
        #expect(twin.isColdPaused)
        let error = try #require(
            await commandError { try await harness.core.resume(.id(twin.id)) })
        #expect(error.isConflict)
        #expect(harness.virtualization.resumeCallCount == 0)

        // Hot-paused: the live object already holds the identity, so refusing
        // would be refusing a VM its own.
        twin.enter(.livePaused(sessionID: UUID()))
        try await harness.core.resume(.id(twin.id))
        #expect(harness.virtualization.resumeCallCount == 1)
    }

    @Test("The machine-identity refusal follows its preference")
    func duplicateMachineIDHonoursThePreference() async throws {
        let harness = makeHarness()
        preferences.blockDuplicateMachineIDBoot = false
        let identity = Data([4, 5, 6])
        let live = makeInstance(in: harness, name: "Live", phase: .running(sessionID: UUID()))
        live.configuration.genericMachineIdentifierData = identity
        let twin = makeInstance(in: harness, name: "Twin")
        twin.configuration.genericMachineIdentifierData = identity

        try await harness.core.start(.id(twin.id), recovery: false)

        #expect(harness.virtualization.startCallCount == 1)
        preferences.blockDuplicateMachineIDBoot = true
    }

    @Test("A start onto a MAC address a live guest already holds is refused")
    func duplicateMACRefusesTheStart() async throws {
        let harness = makeHarness()
        let live = makeInstance(in: harness, name: "Live", phase: .running(sessionID: UUID()))
        live.configuration.networkEnabled = true
        live.configuration.macAddress = "aa:bb:cc:dd:ee:ff"
        let twin = makeInstance(in: harness, name: "Twin")
        twin.configuration.networkEnabled = true
        twin.configuration.macAddress = "AA:BB:CC:DD:EE:FF"

        let error = try #require(
            await commandError { try await harness.core.start(.id(twin.id), recovery: false) })
        guard case .conflict(_, let other, let reason) = error else {
            Issue.record("expected a conflict refusal, got \(error)")
            return
        }
        #expect(other.id == live.id)
        #expect(reason == .macAddress)
    }

    // MARK: - Consent

    @Test("A force stop with no consent refuses, describing what confirming does")
    func forceStopAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Runner", phase: .running(sessionID: UUID()))

        let error = try #require(
            await commandError {
                try await harness.core.stop(
                    .id(instance.id), disposition: .force, confirmed: false)
            })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .forceStop)
        #expect(prompt.title == "Force Stop Virtual Machine")
        #expect(prompt.confirmTitle == "Force Stop")
        #expect(prompt.message.contains("immediately terminated"))
        #expect(prompt.alternatives.map(\.disposition) == [.graceful])
        #expect(harness.virtualization.forceStopCallCount == 0)

        try await harness.core.stop(.id(instance.id), disposition: .force, confirmed: true)
        #expect(harness.virtualization.forceStopCallCount == 1)
    }

    @Test("A cold-paused VM's force stop is worded as discarding its saved state")
    func forceStopOfAColdPausedVMIsADiscard() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Suspended", phase: .suspended)

        let error = try #require(
            await commandError {
                try await harness.core.stop(
                    .id(instance.id), disposition: .force, confirmed: false)
            })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.title == "Discard Saved State")
        #expect(prompt.confirmTitle == "Discard")
        // A paused VM routes its graceful stop through the stop-paused refusal,
        // so this one offers no shutdown alternative.
        #expect(prompt.alternatives.isEmpty)
    }

    @Test("A graceful stop of a live-paused VM refuses with both ways out")
    func stopPausedAsksWhichWayOut() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Paused", phase: .livePaused(sessionID: UUID()))

        let error = try #require(
            await commandError {
                try await harness.core.stop(
                    .id(instance.id), disposition: .graceful, confirmed: false)
            })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .stopPaused)
        #expect(prompt.confirmTitle == "Resume and Shut Down")
        #expect(prompt.alternatives.map(\.disposition) == [.force])
        #expect(harness.virtualization.stopCallCount == 0)

        // Confirming takes the graceful route the guest can only receive awake.
        try await harness.core.stop(.id(instance.id), disposition: .graceful, confirmed: true)
        #expect(harness.virtualization.resumeCallCount == 1)
        #expect(harness.virtualization.stopCallCount == 1)
    }

    @Test("A cold-paused VM's graceful stop asks the consent its force path does")
    func gracefulStopOfAColdPausedVMAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Suspended", phase: .suspended)

        // Not a shutdown at heart: `VirtualizationService.stop` discards the
        // save file for any cold-paused VM, ephemeral or not.
        let error = try #require(
            await commandError {
                try await harness.core.stop(
                    .id(instance.id), disposition: .graceful, confirmed: false)
            })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .forceStop)
        #expect(prompt.title == "Discard Saved State")
        #expect(prompt.confirmTitle == "Discard")
        #expect(harness.virtualization.stopCallCount == 0)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, confirmed: true)
        #expect(harness.virtualization.stopCallCount == 1)
    }

    @Test("A cold-paused Ephemeral VM's graceful stop asks the consent its force path does")
    func gracefulStopOfAColdPausedEphemeralVMAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Ephemeral", phase: .suspended)
        let baseline = VMSnapshot(name: "Clean install")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [baseline])
        instance.configuration.applyEphemeralMode(enabled: true, baseline: baseline.id)
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: baseline.id)

        // Nothing to shut down: this stop deletes the suspended session and
        // rolls the disks back, which is what the force path refuses unconfirmed.
        let error = try #require(
            await commandError {
                try await harness.core.stop(
                    .id(instance.id), disposition: .graceful, confirmed: false)
            })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .forceStop)
        #expect(prompt.title == "Discard Saved State")
        #expect(prompt.confirmTitle == "Revert to Baseline")
        #expect(harness.virtualization.revertedSnapshots.isEmpty)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, confirmed: true)
        #expect(harness.virtualization.revertedSnapshots.map(\.id) == [baseline.id])
    }

    @Test("A VM delete with no consent refuses and touches nothing")
    func deleteAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")

        let error = try #require(
            await commandError {
                try await harness.core.delete(
                    .id(instance.id), permanently: false, alsoRemoving: [], confirmed: false)
            })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .deleteVM)
        #expect(prompt.confirmTitle == "Move to Trash")
        #expect(harness.storage.deleteVMBundleCallCount == 0)
        #expect(harness.library.instances.count == 1)
    }

    @Test("A permanent delete says so in the consent it asks for")
    func permanentDeletePromptNamesTheDisposition() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")

        let error = try #require(
            await commandError {
                try await harness.core.delete(
                    .id(instance.id), permanently: true, alsoRemoving: [], confirmed: false)
            })
        #expect(try #require(error.confirmationPrompt).confirmTitle == "Delete Immediately")
    }

    @Test("A snapshot delete with no consent refuses, and confirming trashes it")
    func deleteSnapshotAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Keeper")
        let snapshot = VMSnapshot(name: "Before")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])

        let error = try #require(
            await commandError {
                try await harness.core.deleteSnapshot(
                    .id(instance.id), snapshot: snapshot.id, confirmed: false)
            })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .deleteSnapshot)
        #expect(prompt.title == "Delete \u{201C}Before\u{201D}?")
        #expect(instance.snapshotManifest.snapshots.count == 1)

        try await harness.core.deleteSnapshot(
            .id(instance.id), snapshot: snapshot.id, confirmed: true)
        #expect(instance.snapshotManifest.isEmpty)
    }

    @Test("A revert with no consent refuses, and offers the check-pointed path")
    func revertAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Reverter", phase: .stopped)
        let snapshot = VMSnapshot(name: "Clean", kind: .cold)
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: snapshot.id)

        let error = try #require(
            await commandError {
                try await harness.core.revertToSnapshot(
                    .id(instance.id), snapshot: snapshot.id, takingCheckpoint: false,
                    confirmed: false)
            })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .revertToSnapshot)
        #expect(prompt.confirmTitle == "Revert")
        #expect(prompt.alternatives.map(\.takesCheckpoint) == [true])
        #expect(harness.virtualization.revertedSnapshots.isEmpty)
    }

    @Test("A cancel with no consent refuses, and confirming marks the row cancelling")
    func cancelPreparingAsksForConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Copying")
        let copy = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: copy)

        let error = try #require(
            commandError { try harness.core.cancelPreparing(.id(instance.id), confirmed: false) })
        let prompt = try #require(error.confirmationPrompt)
        #expect(prompt.kind == .cancelPreparing)
        #expect(prompt.confirmTitle == "Cancel Clone")
        #expect(instance.preparingState?.isCancelling == false)

        try harness.core.cancelPreparing(.id(instance.id), confirmed: true)
        #expect(instance.preparingState?.isCancelling == true)
        copy.cancel()
        instance.preparingState = nil
    }

    @Test("A cancel aimed at a VM that is not copying has no confirmation to ask for")
    func cancelPreparingRefusesAnOrdinaryVM() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Settled")

        let error = try #require(
            commandError { try harness.core.cancelPreparing(.id(instance.id), confirmed: false) })
        #expect(error.isInvalidState)
        #expect(harness.library.instances.count == 1)
    }

    @Test("A cancel confirmed after the copy settled still removes the row and the bundle")
    func cancelPreparingAfterTheCopySettledCleansUp() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Copied")
        // The confirmation sheet is window-modal but nothing pauses the copy, so
        // it can finish while the sheet is up — leaving a completed VM behind
        // that the user has just asked not to have.
        instance.preparingState = nil

        try harness.core.cancelPreparing(.id(instance.id), confirmed: true)

        #expect(harness.library.instances.isEmpty)
        try await harness.fileSystem.recorded.wait {
            harness.fileSystem.trashedURLs == [instance.bundleURL]
        }
    }

    @Test("A cancel confirmed after the settled clone was started refuses rather than trashing it")
    func cancelPreparingAfterTheCopySettledRefusesALiveVM() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Copied")
        // The sheet leaves the menu key equivalents live, so the finished clone
        // can be running by the time the stale confirm lands — and its bundle
        // holds the disks that guest is booted off.
        instance.preparingState = nil
        instance.enter(.running(sessionID: UUID()))

        let error = try #require(
            commandError { try harness.core.cancelPreparing(.id(instance.id), confirmed: true) })

        #expect(error.isInvalidState)
        #expect(harness.library.instances.count == 1)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    // MARK: - Snapshots

    @Test("A capture lands in the manifest, stamped by what the VM could capture")
    func takeSnapshotLandsInTheManifest() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        let summary = try await harness.core.takeSnapshot(
            .id(instance.id), name: "  Fresh  ", notes: " a note ")

        #expect(summary.name == "Fresh")
        #expect(summary.notes == "a note")
        #expect(summary.kind == "warm")
        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Fresh"])
    }

    @Test("A capture refused at the confirm leaves the manifest alone")
    func takeSnapshotRechecksTheGate() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .revertingToSnapshot)

        let error = try #require(
            await commandError {
                _ = try await harness.core.takeSnapshot(
                    .id(instance.id), name: "Too late", notes: "")
            })
        #expect(error.isBusy || error.isInvalidState)
        #expect(instance.snapshotManifest.isEmpty)
    }

    @Test("Every snapshot verb refuses as busy while an operation settles")
    func snapshotVerbsRefuseWhileAnOperationSettles() async throws {
        let harness = makeSuspendingHarness()
        harness.virtualization.shouldSuspendOnResume = true
        let snapshot = VMSnapshot(name: "Clean install")
        let instance = makeInstance(
            in: harness, name: "Settling", phase: .livePaused(sessionID: UUID()),
            snapshots: [snapshot])

        let resume = Task { @MainActor in try await harness.core.resume(.id(instance.id)) }
        await harness.virtualization.waitUntilSuspended()

        // The VM's own state admits all three — what refuses them is the resume
        // still settling, which is something the user can wait out rather than
        // a state the VM is not in.
        let take = try #require(
            await commandError {
                _ = try await harness.core.takeSnapshot(.id(instance.id), name: "Now", notes: "")
            })
        #expect(take.isBusy)
        let revert = try #require(
            await commandError {
                try await harness.core.revertToSnapshot(
                    .id(instance.id), snapshot: snapshot.id, takingCheckpoint: false,
                    confirmed: true)
            })
        #expect(revert.isBusy)
        let delete = try #require(
            await commandError {
                try await harness.core.deleteSnapshot(
                    .id(instance.id), snapshot: snapshot.id, confirmed: true)
            })
        #expect(delete.isBusy)
        #expect(instance.snapshotManifest.snapshots.map(\.name) == ["Clean install"])

        harness.virtualization.resumeSuspended()
        try await resume.value
    }

    @Test("A failed capture reports the failure and lists nothing")
    func takeSnapshotFailureIsReported() async throws {
        let harness = makeHarness()
        harness.virtualization.takeSnapshotError = VMSnapshotError.captureSourceMissing("Disk.asif")
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        let error = try #require(
            await commandError {
                _ = try await harness.core.takeSnapshot(.id(instance.id), name: "Doomed", notes: "")
            })
        guard case .operationFailed(let verb, _, _, _) = error else {
            Issue.record("expected an operation failure, got \(error)")
            return
        }
        #expect(verb == .takeSnapshot)
        #expect(instance.snapshotManifest.isEmpty)
    }

    @Test("A revert taking a check-point aborts rather than reverting when the capture fails")
    func checkPointedRevertAbortsOnCaptureFailure() async throws {
        let harness = makeHarness()
        harness.virtualization.takeSnapshotError = VMSnapshotError.captureSourceMissing("Disk.asif")
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        let snapshot = VMSnapshot(name: "Clean")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: snapshot.id)

        _ = await commandError {
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, takingCheckpoint: true, confirmed: true)
        }

        #expect(harness.virtualization.revertedSnapshots.isEmpty)
    }

    @Test("A snapshot the manifest no longer lists refuses by name")
    func unlistedSnapshotRefuses() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        let error = try #require(
            await commandError {
                try await harness.core.deleteSnapshot(
                    .id(instance.id), snapshot: UUID(), confirmed: true)
            })
        guard case .operationFailed(let verb, _, let message, _) = error else {
            Issue.record("expected an operation failure, got \(error)")
            return
        }
        #expect(verb == .deleteSnapshot)
        #expect(message.contains("no snapshot"))
    }

    @Test("The Ephemeral baseline is refused a delete even with consent")
    func ephemeralBaselineCannotBeDeleted() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let baseline = VMSnapshot(name: "Clean install")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [baseline])
        instance.configuration.applyEphemeralMode(enabled: true, baseline: baseline.id)

        let error = try #require(
            await commandError {
                try await harness.core.deleteSnapshot(
                    .id(instance.id), snapshot: baseline.id, confirmed: true)
            })
        guard case .unsupported(let capability) = error else {
            Issue.record("expected an unsupported refusal, got \(error)")
            return
        }
        #expect(capability.contains("Ephemeral"))
        #expect(instance.snapshotManifest.snapshots.count == 1)
    }

    @Test("Renaming and annotating a snapshot writes through to the manifest")
    func snapshotMetadataWritesThrough() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let snapshot = VMSnapshot(name: "Old", notes: "old note")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])

        try harness.core.renameSnapshot(.id(instance.id), snapshot: snapshot.id, to: "  New  ")
        try harness.core.setSnapshotNotes(.id(instance.id), snapshot: snapshot.id, notes: "  ")

        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.name == "New")
        #expect(instance.snapshotManifest.snapshot(id: snapshot.id)?.notes == "")
        #expect(
            harness.snapshots.manifest(for: instance.bundleURL)?.snapshot(id: snapshot.id)?.name
                == "New")
    }

    @Test("A metadata edit that would change nothing is a no-op, snapshot listed or not")
    func snapshotMetadataNoOpNeedsNoSnapshot() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let snapshot = VMSnapshot(name: "Kept", notes: "a note")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])

        // Unchanged commits against a listed snapshot write nothing.
        #expect(
            commandError {
                try harness.core.renameSnapshot(.id(instance.id), snapshot: snapshot.id, to: "Kept")
            } == nil)
        #expect(
            commandError {
                try harness.core.setSnapshotNotes(
                    .id(instance.id), snapshot: snapshot.id, notes: "a note")
            } == nil)

        // The row can be deleted while its field editor is open, and the
        // end-editing commit that follows names a snapshot that is gone: still
        // nothing to write, so still no alert naming a raw identifier.
        let gone = UUID()
        #expect(
            commandError {
                try harness.core.renameSnapshot(.id(instance.id), snapshot: gone, to: "Kept")
            } == nil)
        #expect(
            commandError {
                try harness.core.setSnapshotNotes(.id(instance.id), snapshot: gone, notes: "a note")
            } == nil)
        #expect(harness.snapshots.manifest(for: instance.bundleURL) == nil)
    }

    // MARK: - Library verbs

    @Test("rename writes the trimmed name through the configuration funnel")
    func renameWritesThrough() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before")

        try harness.core.rename(.id(instance.id), to: "  After  ")

        #expect(instance.name == "After")
    }

    @Test("rename lands on a VM that started transitioning while the field was open")
    func renamePersistsThroughATransition() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before", phase: .saving(sessionID: UUID()))

        // The rename rewrites the configuration's name and nothing the suspend
        // reads, so the typed name lands rather than being traded for an alert.
        try harness.core.rename(.id(instance.id), to: "After")

        #expect(instance.name == "After")
        #expect(harness.core.allowedVerbs(for: instance).contains(.rename))
    }

    @Test("rename refuses during a revert, which would assign the old name back")
    func renameRefusesDuringARestore() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before", phase: .revertingToSnapshot)

        // The revert reads the configuration it assigns back before it starts
        // writing, so a name landing now would be silently overwritten —
        // answering `ok` for a rename the user is about to lose.
        #expect(
            commandError { try harness.core.rename(.id(instance.id), to: "After") }?
                .isInvalidState == true)
        #expect(instance.name == "Before")
        #expect(!harness.core.allowedVerbs(for: instance).contains(.rename))
    }

    @Test("rename refuses only a VM whose clone or import is still copying")
    func renameRefusesAPreparingVM() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Copying")
        instance.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: Task {})

        #expect(
            commandError { try harness.core.rename(.id(instance.id), to: "After") }?.isBusy == true)
        #expect(instance.name == "Copying")
        instance.preparingState = nil
    }

    @Test("clone registers a copying row and refuses a VM that is not at rest")
    func cloneRegistersAPhantom() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")

        let summary = try harness.core.clone(.id(instance.id), machineIdentity: .new)

        #expect(harness.library.instances.count == 2)
        #expect(harness.library.instances.contains { $0.id == summary.id })
        let phantom = harness.library.instances.first { $0.id == summary.id }
        #expect(phantom?.preparingState?.operation == .cloning(sourceID: instance.id))
        for task in harness.library.instances.compactMap({ $0.preparingState?.task }) {
            await task.value
        }

        instance.enter(.running(sessionID: UUID()))
        #expect(
            commandError { _ = try harness.core.clone(.id(instance.id), machineIdentity: .new) }?
                .isInvalidState == true)
    }

    @Test("A delete of a VM whose clone is still copying is refused as busy")
    func deleteRefusesASourceBeingCloned() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        let phantom = makeInstance(in: harness, name: "Source Copy")
        let task = Task {}
        defer { task.cancel() }
        phantom.preparingState = VMInstance.PreparingState(
            operation: .cloning(sourceID: instance.id), task: task)

        let deleteError = try #require(
            await commandError {
                try await harness.core.delete(
                    .id(instance.id), permanently: false, alsoRemoving: [], confirmed: true)
            })
        guard case .busy(let vm, let operation) = deleteError else {
            Issue.record("expected a busy refusal, got \(deleteError)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(operation == "being cloned")
        #expect(harness.library.instances.contains { $0.id == instance.id })
    }

    @Test("delete trashes the bundle and drops the row")
    func deleteRemovesTheVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")

        try await harness.core.delete(
            .id(instance.id), permanently: false, alsoRemoving: [], confirmed: true)

        #expect(harness.library.instances.isEmpty)
        #expect(harness.storage.deleteVMBundleCallCount == 1)
    }

    @Test("A delete that could not trash the bundle leaves the VM naming its suspend slot")
    func failedDeleteKeepsTheSuspendedPhase() async throws {
        let harness = makeHarness()
        harness.storage.deleteVMBundleError = VMStorageError.bundleNotFound(
            URL(filePath: "/tmp/Doomed.kernova"))
        let instance = makeInstance(in: harness, name: "Doomed", phase: .suspended)

        await #expect(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], confirmed: true)
        }

        // The bundle — and the slot inside it — is still on disk, so a VM that
        // survived the delete has to keep offering Resume rather than reading
        // as a stopped VM whose next capture would be stamped disks-only.
        #expect(harness.library.instances.contains { $0 === instance })
        #expect(instance.phase == .suspended)
        #expect(instance.canResume)
    }

    @Test("A repeat delete of an already-removed VM refuses as not found")
    func deleteRefusesARepeatConfirm() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")

        try await harness.core.delete(
            .id(instance.id), permanently: false, alsoRemoving: [], confirmed: true)
        let error = try #require(
            await commandError {
                try await harness.core.delete(
                    .id(instance.id), permanently: false, alsoRemoving: [], confirmed: true)
            })

        #expect(error.isNotFound)
        #expect(harness.storage.deleteVMBundleCallCount == 1)
    }

    @Test("delete refuses a VM that stopped being deletable while the sheet was up")
    func deleteRefusesANoLongerDeletableVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Started", phase: .running(sessionID: UUID()))

        let error = try #require(
            await commandError {
                try await harness.core.delete(
                    .id(instance.id), permanently: false, alsoRemoving: [], confirmed: true)
            })

        #expect(error.isInvalidState)
        #expect(harness.storage.deleteVMBundleCallCount == 0)
        #expect(harness.library.instances.count == 1)
    }

    @Test("delete never removes an external another VM still references")
    func deleteKeepsSharedExternals() async throws {
        let harness = makeHarness()
        let sharedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString).img")
            .path(percentEncoded: false)
        let sharedID = UUID()
        let target = makeInstance(in: harness, name: "Target")
        target.configuration.storageDisks = [
            StorageDisk(
                id: sharedID, path: sharedPath, readOnly: false, label: "Shared",
                isInternal: false, kind: .virtio)
        ]
        let other = makeInstance(in: harness, name: "Other")
        other.configuration.storageDisks = [
            StorageDisk(
                path: sharedPath, readOnly: false, label: "Shared", isInternal: false,
                kind: .virtio)
        ]

        try await harness.core.delete(
            .id(target.id), permanently: false, alsoRemoving: [sharedID], confirmed: true)

        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(harness.fileSystem.removedURLs.isEmpty)
    }

    @Test("A permanent delete of an external bypasses the Trash")
    func permanentDeleteRemovesExternalsOutright() async throws {
        let harness = makeHarness()
        let externalPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString).img")
            .path(percentEncoded: false)
        let diskID = UUID()
        let instance = makeInstance(in: harness, name: "Target")
        instance.configuration.storageDisks = [
            StorageDisk(
                id: diskID, path: externalPath, readOnly: false, label: "External",
                isInternal: false, kind: .virtio)
        ]

        try await harness.core.delete(
            .id(instance.id), permanently: true, alsoRemoving: [diskID], confirmed: true)

        #expect(harness.fileSystem.removedURLs.map(\.path) == [externalPath])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(harness.storage.permanentlyDeleteVMBundleCallCount == 1)
    }

    // MARK: - Storage Disk Lookup

    @Test("storageDisk(id:on:) resolves the synthesized main disk over an empty configured list")
    func storageDiskLookupResolvesSynthesizedMainDiskForEmptyList() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.configuration.storageDisks = []

        let mainDisk = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: instance.bundleURL))

        #expect(harness.core.storageDisk(id: mainDisk.id, on: instance) == mainDisk)
    }

    // MARK: - Events

    @Test("The event stream reports what changed, and nothing a listing already answers")
    func eventsReportChanges() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Watched")

        var events = VMLibraryEventReader(harness.core.events())
        // A fresh subscriber is told what happens from here, not replayed the
        // library it can already list.
        instance.enter(.running(sessionID: UUID()))

        let first = try #require(await events.next())
        guard case .statusChanged(let id, let name, let from, let to) = first else {
            Issue.record("expected a status change, got \(first)")
            return
        }
        #expect(id == instance.id)
        #expect(name == "Watched")
        #expect(from == "stopped")
        #expect(to == "running")
    }

    @Test("A VM joining and leaving the library is reported")
    func eventsReportMembership() async throws {
        let harness = makeHarness()
        var events = VMLibraryEventReader(harness.core.events())

        let instance = makeInstance(in: harness, name: "Arrived")
        let added = try #require(await events.next())
        guard case .added(let summary) = added else {
            Issue.record("expected an addition, got \(added)")
            return
        }
        #expect(summary.name == "Arrived")

        harness.library.evict(instance)
        let removed = try #require(await events.next())
        guard case .removed(let id, let name) = removed else {
            Issue.record("expected a removal, got \(removed)")
            return
        }
        #expect(id == instance.id)
        #expect(name == "Arrived")
    }

    @Test("A VM landing in its error state reports the message it carries")
    func eventsReportFailures() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Broken", phase: .running(sessionID: UUID()))
        var events = VMLibraryEventReader(harness.core.events())

        instance.enter(.failed(message: "The disk went away"))

        var failure: VMLibraryEvent?
        while let event = await events.next() {
            if case .failure = event {
                failure = event
                break
            }
        }
        guard case .failure(_, _, let message)? = failure else {
            Issue.record("expected a failure event")
            return
        }
        #expect(message == "The disk went away")
    }

    @Test("A clone reports the preparing wire status until its copy settles")
    func cloneReportsPreparingWireStatus() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")

        let summary = try harness.core.clone(.id(instance.id), machineIdentity: .new)

        #expect(summary.status == "preparing")
        #expect(harness.core.list().first { $0.id == summary.id }?.status == "preparing")
        #expect(try harness.core.info(.id(summary.id)).status == "preparing")

        for task in harness.library.instances.compactMap({ $0.preparingState?.task }) {
            await task.value
        }
    }

    @Test("A preparing phantom's addition reports the preparing wire status")
    func addedEventReportsPreparingStatus() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        var events = VMLibraryEventReader(harness.core.events())

        let summary = try harness.core.clone(.id(instance.id), machineIdentity: .new)

        var added: VMLibraryEvent?
        while let event = await events.next() {
            if case .added(let phantomSummary) = event, phantomSummary.id == summary.id {
                added = event
                break
            }
        }
        guard case .added(let phantomSummary)? = added else {
            Issue.record("expected an addition")
            return
        }
        #expect(phantomSummary.status == "preparing")

        for task in harness.library.instances.compactMap({ $0.preparingState?.task }) {
            await task.value
        }
    }

    @Test("A preparing row settling reports the wire-status transition")
    func preparingSettleReportsStatusChanged() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Cloning")
        instance.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: Task {})

        var events = VMLibraryEventReader(harness.core.events())
        instance.preparingState = nil

        let event = try #require(await events.next())
        guard case .statusChanged(let id, let name, let from, let to) = event else {
            Issue.record("expected a status change, got \(event)")
            return
        }
        #expect(id == instance.id)
        #expect(name == "Cloning")
        #expect(from == "preparing")
        #expect(to == "stopped")
    }

    @Test("A clone whose copy fails reports the failure directly, then the phantom's removal")
    func cloneFailureReportsFailureThenRemoval() async throws {
        let harness = makeHarness()
        let cloneError = VMStorageError.bundleAlreadyExists(URL(filePath: "/tmp/occupied.kernova"))
        harness.storage.cloneVMBundleError = cloneError
        let instance = makeInstance(in: harness, name: "Source")
        var events = VMLibraryEventReader(harness.core.events())

        let summary = try harness.core.clone(.id(instance.id), machineIdentity: .new)
        let phantom = try #require(harness.library.instances.first { $0.id == summary.id })
        await phantom.preparingState?.task.value

        var failure: VMLibraryEvent?
        while let event = await events.next() {
            if case .failure = event {
                failure = event
                break
            }
        }
        guard case .failure(let id, _, let message)? = failure else {
            Issue.record("expected a failure event")
            return
        }
        #expect(id == phantom.id)
        #expect(message == cloneError.localizedDescription)

        let removed = try #require(await events.next())
        guard case .removed(let removedID, _) = removed else {
            Issue.record("expected a removal, got \(removed)")
            return
        }
        #expect(removedID == phantom.id)
    }

    @Test("A clone left with no disk fails rather than publishing a re-synthesized Disk.asif")
    func cloneWithNoCopiableDiskFails() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        // The source's only disk is an additional internal one whose file is
        // gone, so the remap skips it and nothing is left to publish.
        let missing = StorageDisk(
            path: "AdditionalDisks/\(UUID().uuidString).asif", label: "Extra", isInternal: true)
        instance.configuration.storageDisks = [missing]
        var events = VMLibraryEventReader(harness.core.events())

        let summary = try harness.core.clone(.id(instance.id), machineIdentity: .new)
        let phantom = try #require(harness.library.instances.first { $0.id == summary.id })
        await phantom.preparingState?.task.value

        var failure: VMLibraryEvent?
        while let event = await events.next() {
            if case .failure = event {
                failure = event
                break
            }
        }
        guard case .failure(let id, _, _)? = failure else {
            Issue.record("expected a failure event")
            return
        }
        #expect(id == phantom.id)
        let removed = try #require(await events.next())
        guard case .removed(let removedID, _) = removed else {
            Issue.record("expected a removal, got \(removed)")
            return
        }
        #expect(removedID == phantom.id)
        #expect(!harness.library.instances.contains { $0.id == phantom.id })
        #expect(harness.storage.lastCloneFilesToCopy?.contains("Disk.asif") == false)
    }

    @Test("A clone copies Disk.asif only while the source still references it")
    func cloneCopiesDiskAsifOnlyWhenReferenced() async throws {
        let harness = makeHarness()
        let withMain = makeInstance(in: harness, name: "With Main")
        withMain.configuration.storageDisks = nil
        let summary = try harness.core.clone(.id(withMain.id), machineIdentity: .new)
        await harness.library.instances.first { $0.id == summary.id }?.preparingState?.task.value
        #expect(harness.storage.lastCloneFilesToCopy?.contains("Disk.asif") == true)

        let withoutMain = makeInstance(in: harness, name: "Without Main")
        withoutMain.configuration.storageDisks = [
            StorageDisk(path: "/tmp/external.img", label: "External", isInternal: false)
        ]
        let external = try harness.core.clone(.id(withoutMain.id), machineIdentity: .new)
        await harness.library.instances.first { $0.id == external.id }?.preparingState?.task.value
        #expect(harness.storage.lastCloneFilesToCopy?.contains("Disk.asif") == false)
    }

    @Test("A rename reports what changed, and refuses a row still copying")
    func renameReportsChangeAndRefusesAPreparingRow() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before")
        var events = VMLibraryEventReader(harness.core.events())

        try harness.core.rename(.id(instance.id), to: "After")

        let event = try #require(await events.next())
        guard case .renamed(let id, let from, let to) = event else {
            Issue.record("expected a rename, got \(event)")
            return
        }
        #expect(id == instance.id)
        #expect(from == "Before")
        #expect(to == "After")

        instance.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: Task {})
        let error = try #require(
            commandError { try harness.core.rename(.id(instance.id), to: "Later") })
        #expect(error.isBusy)
        instance.preparingState = nil
    }

    // MARK: - Where failures go

    @Test("A revert that failed is thrown to the caller that awaited it")
    func failedRevertThrowsToItsCaller() async throws {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        var reported: [CommandError] = []
        harness.core.onFailure = { failure, _ in reported.append(failure) }
        let instance = makeInstance(in: harness, name: "Reverter", phase: .running(sessionID: UUID()))
        let snapshot = VMSnapshot(name: "Clean")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: snapshot.id)

        let error = try #require(
            await commandError {
                try await harness.core.revertToSnapshot(
                    .id(instance.id), snapshot: snapshot.id, takingCheckpoint: false,
                    confirmed: true)
            })

        #expect(error.isOperationFailure)
        // Thrown, not reported: a rollback that did not happen must not read as
        // `ok` to whoever asked for it.
        #expect(reported.isEmpty)
        #expect(instance.snapshotManifest.currentID == nil)
    }

    @Test("A cold-paused ephemeral stop throws when its baseline could not come back")
    func failedDiscardRevertThrowsFromStop() async throws {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        let instance = makeInstance(in: harness, name: "Ephemeral", phase: .suspended)
        let baseline = VMSnapshot(name: "Clean install")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [baseline])
        instance.configuration.applyEphemeralMode(enabled: true, baseline: baseline.id)
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: baseline.id)

        let error = try #require(
            await commandError {
                try await harness.core.stop(
                    .id(instance.id), disposition: .graceful, confirmed: true)
            })

        #expect(error.isOperationFailure)
        #expect(harness.virtualization.stopCallCount == 0)
    }

    @Test("A revert nobody awaited reports through the hook, typed")
    func unawaitedRevertFailureLeavesThroughTheHook() async throws {
        let harness = makeHarness()
        harness.virtualization.revertToSnapshotError = VMSnapshotError.snapshotMissingSavedState
        var reported: [CommandError] = []
        harness.core.onFailure = { failure, _ in reported.append(failure) }

        let instance = makeInstance(in: harness, name: "Ephemeral", phase: .running(sessionID: UUID()))
        let baseline = VMSnapshot(name: "Clean install")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [baseline])
        instance.configuration.applyEphemeralMode(enabled: true, baseline: baseline.id)
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: baseline.id)

        // A power-off revert has no call waiting on it, so its failure has only
        // the hook to leave through.
        harness.core.revertToEphemeralBaselineIfNeeded(instance)
        await harness.library.waitForRevertsToSettle()

        #expect(reported.count == 1)
        #expect(reported.first?.isOperationFailure == true)
    }

    @Test("A create whose disk image failed reports the failure typed as a create")
    func failedCreateReportsThroughTheHookTyped() async throws {
        let diskImages = MockDiskImageService()
        diskImages.createDiskImageError = NSError(domain: "test", code: 1)
        let harness = makeHarness(diskImages: diskImages)
        var reported: [CommandError] = []
        harness.core.onFailure = { failure, _ in reported.append(failure) }

        // The write fails after the phantom row is registered, so the sheet
        // that asked is long gone and the hook is all the failure has.
        let summary = try harness.core.create(
            configuration: VMConfiguration(name: "Disk Fail VM", guestOS: .linux, bootMode: .efi),
            startAfterCreate: false)
        await harness.library.instances.first { $0.id == summary.id }?.preparingState?.task.value

        #expect(harness.library.instances.isEmpty)
        guard case .operationFailed(let verb, _, _, _) = reported.first else {
            Issue.record("Expected an operationFailed, got \(String(describing: reported.first))")
            return
        }
        #expect(verb == .create)
    }

    @Test("A start failure that names its own heading carries it to the caller")
    func startFailureNamesItsOwnHeading() async throws {
        let harness = makeHarness()
        harness.virtualization.startError = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.virtualMachineLimitExceeded.rawValue)
        let instance = makeInstance(in: harness, name: "Capped")

        let error = try #require(
            await commandError { try await harness.core.start(.id(instance.id), recovery: false) })

        // The heading a wire caller must get too — pinned there by
        // `operationFailureTitleCrossesTheWire`.
        #expect(error.alertTitle == "Couldn't Start \u{201C}Capped\u{201D}")
    }

    @Test("A rename that did not reach disk is reported rather than answered ok")
    func failedRenameIsReported() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before")
        harness.storage.saveConfigurationError = VMStorageError.bundleNotFound(instance.bundleURL)

        let error = try #require(
            commandError { try harness.core.rename(.id(instance.id), to: "After") })

        #expect(error.isOperationFailure)
    }

    @Test("A rename that changes nothing is a no-op even mid-operation")
    func unchangedRenameIsNotRefused() throws {
        let harness = makeHarness()
        // Both inline-rename surfaces commit on end-editing whether or not the
        // text changed, so an unchanged commit landing here must not refuse.
        let instance = makeInstance(in: harness, name: "Steady", phase: .saving(sessionID: UUID()))

        #expect(commandError { try harness.core.rename(.id(instance.id), to: "Steady") } == nil)
        #expect(commandError { try harness.core.rename(.id(instance.id), to: "   ") } == nil)
        #expect(instance.name == "Steady")
    }

    @Test("The invalid-state message names verbs the way a person does")
    func invalidStateMessageReadsAsCopy() throws {
        let harness = makeHarness()
        // Stopped: there is no display to open, and the state admits both a
        // start and a disks-only capture, so the sentence has something to list.
        let instance = makeInstance(in: harness, name: "Resting", phase: .stopped)

        let error = try #require(commandError { try harness.core.open(.id(instance.id)) })

        // A wire name never reaches a user, and a read is admitted in every
        // state, so naming one says nothing.
        #expect(error.message.contains("Take Snapshot"))
        #expect(!error.message.contains("takeSnapshot"))
        #expect(!error.message.contains("ipAddress"))
    }

    @Test("A restart waits out the baseline revert its own shutdown started")
    func restartWaitsOutTheEphemeralRevert() async throws {
        let harness = makeSuspendingHarness()
        harness.virtualization.shouldSuspendOnRevert = true
        let instance = makeInstance(
            in: harness, name: "Ephemeral", phase: .running(sessionID: UUID()))
        let baseline = VMSnapshot(name: "Clean install")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [baseline])
        instance.configuration.applyEphemeralMode(enabled: true, baseline: baseline.id)
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: baseline.id)

        let restart = Task { try await harness.core.restart(.id(instance.id)) }
        // The stop powers the guest off, which queues the baseline revert; the
        // revert then parks mid-copy. The VM already reads `.stopped` here, so
        // only the revert registry holds the restart back.
        await harness.virtualization.waitUntilSuspended()
        #expect(harness.library.hasRevertInFlight(for: instance.id))
        #expect(instance.status == .stopped)

        harness.virtualization.resumeSuspended()
        try await restart.value

        // The baseline handed the VM back suspended on its own memory image, so
        // the restart resumed it rather than waiting for a `.stopped` that was
        // never coming.
        #expect(instance.status == .running)
        #expect(!harness.library.hasRevertInFlight(for: instance.id))
    }

    @Test("A restart of an ordinary VM boots it once the power-off settles")
    func restartBootsAnOrdinaryVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Plain", phase: .running(sessionID: UUID()))

        try await harness.core.restart(.id(instance.id))

        #expect(harness.virtualization.stopCallCount == 1)
        #expect(harness.virtualization.startCallCount == 1)
        #expect(instance.status == .running)
    }
}

extension CommandError {
    fileprivate var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    fileprivate var isInvalidState: Bool {
        if case .invalidState = self { return true }
        return false
    }

    fileprivate var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }
}

/// The core's batched event stream, read one event at a time.
///
/// A pass over the library delivers every change it found as one element, so a
/// case asserting on the order changes arrived in flattens the batches back
/// out.
private struct VMLibraryEventReader {
    private var batches: AsyncStream<[VMLibraryEvent]>.AsyncIterator
    private var pending: [VMLibraryEvent] = []

    init(_ stream: AsyncStream<[VMLibraryEvent]>) {
        batches = stream.makeAsyncIterator()
    }

    /// The next event, awaiting another batch once the current one is spent.
    mutating func next() async -> VMLibraryEvent? {
        while pending.isEmpty {
            guard let batch = await batches.next() else { return nil }
            pending = batch
        }
        return pending.removeFirst()
    }
}
