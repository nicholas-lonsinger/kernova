import Foundation
import KernovaKit
import Testing

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
    }

    private func makeHarness(
        virtualization: MockVirtualizationService = MockVirtualizationService()
    ) -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMSnapshotStore()
        let fileSystem = MockFileSystem()
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
            fileSystem: fileSystem,
            preferences: preferences
        )
        return Harness(
            core: core, library: library, lifecycle: lifecycle, storage: storage,
            virtualization: virtualization, snapshots: snapshots, fileSystem: fileSystem)
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
            fileSystem: fileSystem,
            preferences: preferences
        )
        return SuspendingHarness(
            core: core, library: library, storage: storage, virtualization: virtualization,
            snapshots: snapshots)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Core VM", status: VMStatus = .stopped,
        guestOS: VMGuestOS = .linux
    ) -> VMInstance {
        register(name: name, status: status, guestOS: guestOS, in: harness.library, harness.storage)
    }

    @discardableResult
    private func makeInstance(
        in harness: SuspendingHarness, name: String = "Core VM", status: VMStatus = .stopped
    ) -> VMInstance {
        register(name: name, status: status, guestOS: .linux, in: harness.library, harness.storage)
    }

    private func register(
        name: String, status: VMStatus, guestOS: VMGuestOS, in library: VMLibrary,
        _ storage: MockVMStorageService
    ) -> VMInstance {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        config.networkEnabled = false
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, status: status, preferences: preferences)
        storage.bundles[bundleURL] = config
        // Wired the way every real construction site is, so the per-instance
        // hooks a verb answers — the power-off that starts an Ephemeral revert,
        // above all — are actually connected.
        library.wirePersistence(for: instance)
        library.instances.append(instance)
        return instance
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
        let second = makeInstance(in: harness, name: "Twin", status: .running)

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
        makeInstance(in: harness, name: "Second", status: .running)

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
        let instance = makeInstance(in: harness, status: .running)

        try await harness.core.pause(.id(instance.id))
        #expect(harness.virtualization.pauseCallCount == 1)

        try await harness.core.resume(.id(instance.id))
        #expect(harness.virtualization.resumeCallCount == 1)

        instance.status = .running
        try await harness.core.suspend(.id(instance.id))
        #expect(harness.virtualization.saveCallCount == 1)
    }

    @Test("A graceful stop of a running VM needs no confirmation")
    func gracefulStopRuns() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, status: .running)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, confirmed: false)

        #expect(harness.virtualization.stopCallCount == 1)
    }

    @Test("open brings the display of a VM that has one to the front")
    func openSurfacesTheDisplay() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, status: .running)
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

    // MARK: - State gates

    @Test("start refuses a VM that is already running")
    func startRefusesARunningVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, status: .running)

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

    // MARK: - Conflicts

    @Test("A start that would put two live guests on one machine identity is refused")
    func duplicateMachineIDRefusesTheStart() async throws {
        let harness = makeHarness()
        preferences.blockDuplicateMachineIDBoot = true
        let identity = Data([1, 2, 3, 4])
        let live = makeInstance(in: harness, name: "Live", status: .running)
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
        let live = makeInstance(in: harness, name: "Live", status: .running)
        live.configuration.genericMachineIdentifierData = identity
        live.hasLiveVirtualMachineOverrideForTesting = true
        let twin = makeInstance(in: harness, name: "Twin", status: .paused)
        twin.configuration.genericMachineIdentifierData = identity

        // Cold-paused: the resume builds a fresh VM and claims the identity.
        #expect(twin.isColdPaused)
        let error = try #require(
            await commandError { try await harness.core.resume(.id(twin.id)) })
        #expect(error.isConflict)
        #expect(harness.virtualization.resumeCallCount == 0)

        // Hot-paused: the live object already holds the identity, so refusing
        // would be refusing a VM its own.
        twin.hasLiveVirtualMachineOverrideForTesting = true
        try await harness.core.resume(.id(twin.id))
        #expect(harness.virtualization.resumeCallCount == 1)
    }

    @Test("The machine-identity refusal follows its preference")
    func duplicateMachineIDHonoursThePreference() async throws {
        let harness = makeHarness()
        preferences.blockDuplicateMachineIDBoot = false
        let identity = Data([4, 5, 6])
        let live = makeInstance(in: harness, name: "Live", status: .running)
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
        let live = makeInstance(in: harness, name: "Live", status: .running)
        live.configuration.networkEnabled = true
        live.configuration.macAddress = "aa:bb:cc:dd:ee:ff"
        live.hasLiveVirtualMachineOverrideForTesting = true
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
        let instance = makeInstance(in: harness, name: "Runner", status: .running)
        instance.hasLiveVirtualMachineOverrideForTesting = true

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
        let instance = makeInstance(in: harness, name: "Suspended", status: .paused)

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
        let instance = makeInstance(in: harness, name: "Paused", status: .paused)
        instance.hasLiveVirtualMachineOverrideForTesting = true

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
        let instance = makeInstance(in: harness, name: "Reverter", status: .stopped)
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
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: copy)

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

    @Test("A cancel aimed at a VM that is not copying is refused rather than run")
    func cancelPreparingRefusesAnOrdinaryVM() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Settled")

        let error = try #require(
            commandError { try harness.core.cancelPreparing(.id(instance.id), confirmed: true) })
        #expect(error.isInvalidState)
        #expect(harness.library.instances.count == 1)
    }

    // MARK: - Snapshots

    @Test("A capture lands in the manifest, stamped by what the VM could capture")
    func takeSnapshotLandsInTheManifest() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, status: .running)

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
        let instance = makeInstance(in: harness, status: .restoring)

        let error = try #require(
            await commandError {
                _ = try await harness.core.takeSnapshot(
                    .id(instance.id), name: "Too late", notes: "")
            })
        #expect(error.isBusy || error.isInvalidState)
        #expect(instance.snapshotManifest.isEmpty)
    }

    @Test("A failed capture reports the failure and lists nothing")
    func takeSnapshotFailureIsReported() async throws {
        let harness = makeHarness()
        harness.virtualization.takeSnapshotError = VMSnapshotError.captureSourceMissing("Disk.asif")
        let instance = makeInstance(in: harness, status: .running)

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
        let instance = makeInstance(in: harness, status: .running)
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

    // MARK: - Library verbs

    @Test("rename writes the trimmed name through the configuration funnel")
    func renameWritesThrough() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before")

        try harness.core.rename(.id(instance.id), to: "  After  ")

        #expect(instance.name == "After")
    }

    @Test("rename refuses a VM mid-operation")
    func renameRefusesATransitioningVM() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before", status: .saving)

        #expect(
            commandError { try harness.core.rename(.id(instance.id), to: "After") }?
                .isInvalidState == true)
        #expect(instance.name == "Before")
    }

    @Test("clone registers a copying row and refuses a VM that is not at rest")
    func cloneRegistersAPhantom() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")

        let summary = try harness.core.clone(.id(instance.id), machineIdentity: .new)

        #expect(harness.library.instances.count == 2)
        #expect(harness.library.instances.contains { $0.id == summary.id })
        for task in harness.library.instances.compactMap({ $0.preparingState?.task }) {
            await task.value
        }

        instance.status = .running
        #expect(
            commandError { _ = try harness.core.clone(.id(instance.id), machineIdentity: .new) }?
                .isInvalidState == true)
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
        let instance = makeInstance(in: harness, name: "Started", status: .running)

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

    // MARK: - Events

    @Test("The event stream reports what changed, and nothing a listing already answers")
    func eventsReportChanges() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Watched")

        var events = harness.core.events().makeAsyncIterator()
        // A fresh subscriber is told what happens from here, not replayed the
        // library it can already list.
        instance.status = .running

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
        var events = harness.core.events().makeAsyncIterator()

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
        let instance = makeInstance(in: harness, name: "Broken", status: .running)
        var events = harness.core.events().makeAsyncIterator()

        instance.errorMessage = "The disk went away"
        instance.status = .error

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
        var events = harness.core.events().makeAsyncIterator()

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
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: Task {})

        var events = harness.core.events().makeAsyncIterator()
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
        let cloneError = VMStorageError.bundleAlreadyExists(UUID())
        harness.storage.cloneVMBundleError = cloneError
        let instance = makeInstance(in: harness, name: "Source")
        var events = harness.core.events().makeAsyncIterator()

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

    @Test("A rename reports what changed, and refuses a row still copying")
    func renameReportsChangeAndRefusesAPreparingRow() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Before")
        var events = harness.core.events().makeAsyncIterator()

        try harness.core.rename(.id(instance.id), to: "After")

        let event = try #require(await events.next())
        guard case .renamed(let id, let from, let to) = event else {
            Issue.record("expected a rename, got \(event)")
            return
        }
        #expect(id == instance.id)
        #expect(from == "Before")
        #expect(to == "After")

        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: Task {})
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
        let instance = makeInstance(in: harness, name: "Reverter", status: .running)
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
        let instance = makeInstance(in: harness, name: "Ephemeral", status: .paused)
        let baseline = VMSnapshot(name: "Clean install")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [baseline])
        instance.configuration.applyEphemeralMode(enabled: true, baseline: baseline.id)
        harness.snapshots.setCapturedConfiguration(instance.configuration, for: baseline.id)

        let error = try #require(
            await commandError {
                try await harness.core.stop(
                    .id(instance.id), disposition: .graceful, confirmed: false)
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

        let instance = makeInstance(in: harness, name: "Ephemeral", status: .running)
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
        let instance = makeInstance(in: harness, name: "Steady", status: .saving)

        #expect(commandError { try harness.core.rename(.id(instance.id), to: "Steady") } == nil)
        #expect(commandError { try harness.core.rename(.id(instance.id), to: "   ") } == nil)
        #expect(
            commandError { try harness.core.rename(.id(instance.id), to: "Moved") }?.isInvalidState
                == true)
    }

    @Test("The invalid-state message names verbs the way a person does")
    func invalidStateMessageReadsAsCopy() throws {
        let harness = makeHarness()
        // Stopped: there is no display to open, and the state admits both a
        // start and a disks-only capture, so the sentence has something to list.
        let instance = makeInstance(in: harness, name: "Resting", status: .stopped)

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
        let instance = makeInstance(in: harness, name: "Ephemeral", status: .running)
        instance.hasLiveVirtualMachineOverrideForTesting = true
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
        let instance = makeInstance(in: harness, name: "Plain", status: .running)
        instance.hasLiveVirtualMachineOverrideForTesting = true

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
