import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import Kernova

/// A stand-in for a wire transport: it encodes a request, hands the bytes to
/// the router, and decodes what comes back — the same round trip a transport
/// makes, with no transport.
@MainActor
private struct TestTransport {
    let router: VMCommandEnvelopeRouter

    func send(_ verb: VMCommandRequest.Verb) async throws -> VMCommandResponse {
        let request = try JSONEncoder().encode(VMCommandRequest(verb: verb))
        let response = await router.handle(request)
        return try JSONDecoder().decode(VMCommandResponse.self, from: response)
    }

    func sendRaw(_ bytes: Data) async throws -> VMCommandResponse {
        try JSONDecoder().decode(VMCommandResponse.self, from: await router.handle(bytes))
    }
}

/// The wire boundary driven end to end against the real command core: a client
/// that can only speak bytes gets the same verbs, the same refusals, and the
/// same consent semantics as the in-process UI.
@Suite("VM Command Envelope Router Tests", .serialized, .admissionGated)
@MainActor
struct VMCommandEnvelopeRouterTests {
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.commandrouter")

    private struct Harness {
        let transport: TestTransport
        let core: VMCommandCore
        let authority: MockImportSourceAuthority
        let library: VMLibrary
        let storage: MockVMStorageService
        let virtualization: MockVirtualizationService
        let snapshots: MockVMSnapshotStore
    }

    /// A transport over anything that speaks the facade, with an authority that
    /// answers every import source unchanged unless the test says otherwise.
    private func makeTransport(
        over commands: any VMCommanding,
        authority: MockImportSourceAuthority = MockImportSourceAuthority()
    ) -> TestTransport {
        TestTransport(
            router: VMCommandEnvelopeRouter(commands: commands, importAuthority: authority))
    }

    private func makeHarness(
        installService: any MacOSInstallProviding = MockMacOSInstallService(),
        virtualization: MockVirtualizationService = MockVirtualizationService(),
        clock: any EngineClock = makePlatformEngineClock()
    ) -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMSnapshotStore()
        let fileSystem = MockFileSystem()
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
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            snapshotStore: snapshots,
            diskImageService: MockDiskImageService(),
            fileSystem: fileSystem,
            preferences: preferences,
            clock: clock
        )
        let authority = MockImportSourceAuthority()
        return Harness(
            transport: makeTransport(over: core, authority: authority),
            core: core, authority: authority,
            library: library, storage: storage, virtualization: virtualization,
            snapshots: snapshots)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Wired", phase: VMLifecyclePhase = .stopped
    ) -> VMInstance {
        var config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        config.networkEnabled = false
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, phase: phase, preferences: preferences)
        harness.library.instances.append(instance)
        harness.storage.bundles[bundleURL] = config
        return instance
    }

    // MARK: - Reads

    @Test("A listing crosses the wire as summaries")
    func listCrossesTheWire() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "First")
        makeInstance(in: harness, name: "Second", phase: .running(sessionID: UUID()))

        let response = try await harness.transport.send(.list)

        guard case .summaries(let summaries) = response.result else {
            Issue.record("expected summaries, got \(response.result)")
            return
        }
        #expect(summaries.map(\.name) == ["First", "Second"])
        #expect(summaries.map(\.status) == ["stopped", "running"])
    }

    @Test("An info read crosses the wire whole")
    func infoCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Described")

        let response = try await harness.transport.send(.info(.name("Described")))

        guard case .info(let info) = response.result else {
            Issue.record("expected info, got \(response.result)")
            return
        }
        #expect(info.id == instance.id)
        #expect(info.guestOS == "linux")
    }

    @Test("Snapshot sizes cross the wire keyed by snapshot")
    func snapshotOnDiskBytesCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Measured")
        let snapshot = VMSnapshot(name: "Clean install")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])
        harness.snapshots.setSize(12_884_901_888, for: snapshot.id)

        let response = try await harness.transport.send(.snapshotOnDiskBytes(.id(instance.id)))

        #expect(response.result == .snapshotSizes([snapshot.id: 12_884_901_888]))
    }

    // MARK: - Verbs

    @Test("A start crosses the wire and reaches the service")
    func startCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        let response = try await harness.transport.send(
            .start(.id(instance.id), recovery: false, presentation: .surface))

        #expect(response.result == .ok)
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("A stop deadline crosses the wire and comes back as a timeout failure")
    func stopDeadlineCrossesTheWire() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let harness = makeHarness(virtualization: virtualization, clock: TestEngineClock())
        let instance = makeInstance(
            in: harness, name: "Stubborn", phase: .running(sessionID: UUID()))

        let response = try await harness.transport.send(
            .stop(.id(instance.id), disposition: .graceful, confirmed: false, timeout: 60))

        guard case .timedOut(let vm, let verb, let seconds) = response.failure else {
            Issue.record("expected a timeout failure, got \(response.result)")
            return
        }
        #expect(vm.id == instance.id)
        #expect(verb == .stop)
        #expect(seconds == 60)
        #expect(instance.status == .running)
    }

    @Test("A snapshot capture answers with the snapshot that landed")
    func takeSnapshotCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        let response = try await harness.transport.send(
            .takeSnapshot(.id(instance.id), name: "Fresh", notes: ""))

        guard case .snapshot(let snapshot) = response.result else {
            Issue.record("expected a snapshot, got \(response.result)")
            return
        }
        #expect(snapshot.name == "Fresh")
        #expect(instance.snapshotManifest.snapshots.count == 1)
    }

    // MARK: - Refusals

    @Test("A selector nothing answers to comes back as a not-found failure")
    func notFoundCrossesTheWire() async throws {
        let harness = makeHarness()

        let response = try await harness.transport.send(.info(.name("Nothing")))

        #expect(response.failure == .notFound(selector: .name("Nothing")))
    }

    @Test("An ambiguous name comes back carrying every candidate")
    func ambiguityCrossesTheWire() async throws {
        let harness = makeHarness()
        let first = makeInstance(in: harness, name: "Twin")
        let second = makeInstance(in: harness, name: "Twin")

        let response = try await harness.transport.send(.info(.name("Twin")))

        guard case .ambiguous(_, let candidates)? = response.failure else {
            Issue.record("expected an ambiguity, got \(String(describing: response.failure))")
            return
        }
        #expect(candidates.map(\.id) == [first.id, second.id])
    }

    @Test("A state gate comes back naming the state and the verbs it allows")
    func invalidStateCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        let response = try await harness.transport.send(
            .start(.id(instance.id), recovery: false, presentation: .surface))

        guard case .invalidState(_, let current, let allowed)? = response.failure else {
            Issue.record("expected an invalid state, got \(String(describing: response.failure))")
            return
        }
        #expect(current == "running")
        #expect(allowed.contains(.stop))
        #expect(!allowed.contains(.start))
    }

    @Test("A destructive verb with no consent comes back as the prompt to gather")
    func consentCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Doomed")

        let refused = try await harness.transport.send(
            .delete(.id(instance.id), permanently: false, alsoRemoving: [], confirmed: false))

        guard case .confirmationRequired(let prompt)? = refused.failure else {
            Issue.record("expected a consent refusal, got \(String(describing: refused.failure))")
            return
        }
        #expect(prompt.kind == .deleteVM)
        #expect(prompt.confirmTitle == "Move to Trash")
        #expect(prompt.dismissTitle == "Cancel")
        #expect(harness.library.instances.count == 1)

        let confirmed = try await harness.transport.send(
            .delete(.id(instance.id), permanently: false, alsoRemoving: [], confirmed: true))

        #expect(confirmed.result == .ok)
        #expect(harness.library.instances.isEmpty)
    }

    @Test("A failure that names its own heading crosses the wire carrying it")
    func operationFailureTitleCrossesTheWire() async throws {
        let harness = makeHarness()
        harness.virtualization.startError = NSError(
            domain: VZError.errorDomain,
            code: VZError.Code.virtualMachineLimitExceeded.rawValue)
        let instance = makeInstance(in: harness, name: "Capped")

        let response = try await harness.transport.send(
            .start(.id(instance.id), recovery: false, presentation: .surface))

        guard case .operationFailed(_, let title, _, _)? = response.failure else {
            Issue.record("expected an operation failure, got \(String(describing: response.failure))")
            return
        }
        // The heading an in-process caller reads off `CommandError.alertTitle`
        // (pinned by `startFailureNamesItsOwnHeading`), not the generic "Error"
        // a dropped title leaves a wire caller with.
        #expect(title == "Couldn't Start \u{201C}Capped\u{201D}")
    }

    // MARK: - Guest Setup

    @Test("An unconfirmed cancel refuses with the confirmation naming the running step")
    func cancelGuestSetupWithoutConsentRefuses() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .installing(sessionID: nil))
        instance.setupTask = Task {}
        instance.setupState = .macOSInstall(hasDownloadStep: false)

        let response = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), confirmed: false))

        guard case .confirmationRequired(let prompt)? = response.failure else {
            Issue.record("expected a consent refusal, got \(String(describing: response.failure))")
            return
        }
        #expect(prompt.kind == .cancelGuestSetup)
        #expect(prompt.title == "Cancel Installation?")
    }

    @Test("A confirmed cancel of a running setup crosses the wire and cancels the task")
    func cancelGuestSetupCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .installing(sessionID: nil))
        let cancelStream = AsyncStream<Void>.makeStream()
        instance.setupTask = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelStream.continuation.yield(())
                cancelStream.continuation.finish()
            }
        }

        let response = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), confirmed: true))

        #expect(response.result == .ok)
        for await _ in cancelStream.stream { break }
    }

    @Test("Cancelling with nothing in flight refuses, and the verb is not offered")
    func cancelGuestSetupWithNothingInFlightRefuses() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped)

        let response = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), confirmed: true))

        guard case .invalidState(_, _, let allowed)? = response.failure else {
            Issue.record("expected an invalid state, got \(String(describing: response.failure))")
            return
        }
        #expect(!allowed.contains(.cancelGuestSetup))
    }

    @Test("A second cancel after the setup task drains refuses, and the VM stays resumable")
    func repeatedCancelGuestSetupRefusesOnceDrained() async throws {
        let installService = SuspendingMockMacOSInstallService()
        let harness = makeHarness(installService: installService)
        var config = VMConfiguration(name: "Installing", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, phase: .initialBoot,
            preferences: preferences)
        harness.library.instances.append(instance)
        harness.storage.bundles[bundleURL] = config

        let started = try await harness.transport.send(
            .start(.id(instance.id), recovery: false, presentation: .surface))
        #expect(started.result == .ok)
        for await _ in installService.installStartedStream { break }

        // The gate covers exactly the setup phase: while the install pipeline
        // is still running, cancelGuestSetup is offered and cancelling it works.
        let firstCancel = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), confirmed: true))
        #expect(firstCancel.result == .ok)

        // Drain the setup task before asserting or firing the second cancel: the
        // window between the cancel and the task's `defer { setupTask = nil }`
        // legitimately still answers `.ok`.
        await instance.setupTask?.value

        #expect(instance.status == .initialBoot)
        #expect(instance.configuration.installContext != nil)

        let secondCancel = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), confirmed: true))
        guard case .invalidState? = secondCancel.failure else {
            Issue.record("expected an invalid state, got \(String(describing: secondCancel.failure))")
            return
        }
    }

    @Test("The cancelGuestSetup gate clears before the chained auto-boot, not after it")
    func cancelGuestSetupGateClosesBeforeAutoBoot() async throws {
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
            library: library, lifecycle: lifecycle, storageService: storage,
            snapshotStore: snapshots, diskImageService: MockDiskImageService(),
            fileSystem: fileSystem, preferences: preferences)
        let transport = makeTransport(over: core)

        var config = VMConfiguration(name: "Installing", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, phase: .initialBoot,
            preferences: preferences)
        library.instances.append(instance)
        storage.bundles[bundleURL] = config

        let started = try await transport.send(.start(.id(instance.id), recovery: false, presentation: .surface))
        #expect(started.result == .ok)

        // The install completes synchronously (`MockMacOSInstallService` has no
        // suspension), so by the time the chained auto-boot reaches the
        // suspending virtualization service's `start`, the setup phase is over
        // and the gate should already be closed.
        await virtualization.waitUntilSuspended()

        let response = try await transport.send(.cancelGuestSetup(.id(instance.id), confirmed: true))
        guard case .invalidState(_, _, let allowed)? = response.failure else {
            Issue.record("expected an invalid state, got \(String(describing: response.failure))")
            return
        }
        #expect(!allowed.contains(.cancelGuestSetup))

        virtualization.resumeSuspended()
    }

    // MARK: - Attachments

    @Test("Each storage-disk edit crosses the wire onto its own facade call")
    func storageDiskEditsCrossTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "stopped", ipAddress: .unavailable)
        double.library = [summary]
        let transport = makeTransport(over: double)
        let selector = VMSelector.id(summary.id)
        let disk = UUID()

        for edit: StorageDiskEdit in [
            .create(sizeInGB: 32),
            .remove(disk: disk, trashFile: true, confirmed: true),
            .rename(disk: disk, newLabel: "Scratch"),
            .setNotes(disk: disk, notes: "the build cache"),
            .setReadOnly(disk: disk, readOnly: true),
            .reorder(order: [disk]),
        ] {
            #expect(try await transport.send(.editStorageDisk(selector, edit)).result == .ok)
        }

        #expect(double.createStorageDiskCalls.map(\.sizeInGB) == [32])
        #expect(double.removeStorageDiskCalls.map(\.disk) == [disk])
        #expect(double.removeStorageDiskCalls.map(\.trashFile) == [true])
        #expect(double.renameStorageDiskCalls.map(\.newLabel) == ["Scratch"])
        #expect(double.setStorageDiskNotesCalls.map(\.notes) == ["the build cache"])
        #expect(double.setStorageDiskReadOnlyCalls.map(\.readOnly) == [true])
        #expect(double.reorderStorageDisksCalls.map(\.order) == [[disk]])
    }

    @Test("Each removable-media edit crosses the wire onto its own facade call")
    func removableMediaEditsCrossTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "running", ipAddress: .unavailable)
        double.library = [summary]
        let transport = makeTransport(over: double)
        let selector = VMSelector.id(summary.id)
        let item = UUID()

        for edit: RemovableMediaEdit in [
            .remove(item: item, trashFile: false, confirmed: true),
            .eject(item: item),
            .rename(item: item, newLabel: "Installer"),
            .setNotes(item: item, notes: "from the mirror"),
            .setReadOnly(item: item, readOnly: false),
        ] {
            #expect(try await transport.send(.editRemovableMedia(selector, edit)).result == .ok)
        }

        #expect(double.removeRemovableMediaCalls.map(\.trashFile) == [false])
        #expect(double.ejectRemovableMediaCalls.map(\.item) == [item])
        #expect(double.renameRemovableMediaCalls.map(\.newLabel) == ["Installer"])
        #expect(double.setRemovableMediaNotesCalls.map(\.notes) == ["from the mirror"])
        #expect(double.setRemovableMediaReadOnlyCalls.map(\.readOnly) == [false])
    }

    @Test("Each shared-directory edit crosses the wire onto its own facade call")
    func sharedDirectoryEditsCrossTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "stopped", ipAddress: .unavailable)
        double.library = [summary]
        let transport = makeTransport(over: double)
        let selector = VMSelector.id(summary.id)
        let directory = UUID()

        for edit: SharedDirectoryEdit in [
            .remove(directory: directory),
            .setReadOnly(directory: directory, readOnly: true),
        ] {
            #expect(try await transport.send(.editSharedDirectory(selector, edit)).result == .ok)
        }

        #expect(double.removeSharedDirectoryCalls.map(\.directory) == [directory])
        #expect(double.setSharedDirectoryReadOnlyCalls.map(\.readOnly) == [true])
    }

    @Test("Both guest-agent-disk edits cross the wire")
    func guestAgentDiskEditsCrossTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "running", ipAddress: .unavailable)
        double.library = [summary]
        let transport = makeTransport(over: double)
        let selector = VMSelector.id(summary.id)

        #expect(try await transport.send(.guestAgentDisk(selector, .mount)).result == .ok)
        #expect(try await transport.send(.guestAgentDisk(selector, .unmount)).result == .ok)

        #expect(double.mountGuestAgentDiskSelectors == [selector])
        #expect(double.unmountGuestAgentDiskSelectors == [selector])
    }

    @Test("A running VM refuses a disk edit over the wire and names what it does take")
    func storageDiskEditRefusedOnARunningVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        let disk = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        instance.configuration.storageDisks = [disk]

        let response = try await harness.transport.send(
            .editStorageDisk(.id(instance.id), .rename(disk: disk.id, newLabel: "New")))

        guard case .invalidState(_, _, let allowed) = try #require(response.failure) else {
            Issue.record("expected an invalid-state refusal, got \(String(describing: response.failure))")
            return
        }
        #expect(!allowed.contains(.editStorageDisk))
        #expect(allowed.contains(.editRemovableMedia))
        #expect(instance.configuration.storageDisks?[0].label == "Extra")
    }

    @Test("A trashing removal refuses over the wire until consent comes with it")
    func trashingRemovalAsksForConsentOverTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")
            .path(percentEncoded: false)
        let disk = StorageDisk(path: path, label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        instance.configuration.storageDisks = [disk, keeper]

        let refused = try await harness.transport.send(
            .editStorageDisk(
                .id(instance.id), .remove(disk: disk.id, trashFile: true, confirmed: false)))
        guard case .confirmationRequired(let prompt) = try #require(refused.failure) else {
            Issue.record("expected a consent refusal, got \(String(describing: refused.failure))")
            return
        }
        #expect(prompt.kind == .removeAttachment)
        #expect(instance.configuration.storageDisks?.count == 2)

        let confirmed = try await harness.transport.send(
            .editStorageDisk(
                .id(instance.id), .remove(disk: disk.id, trashFile: true, confirmed: true)))
        #expect(confirmed.result == .ok)
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
    }

    // MARK: - Import

    @Test("An import copies the bundle the authority made readable, not the path sent")
    func importGoesThroughTheAuthority() async throws {
        let double = MockVMCommanding()
        let authority = MockImportSourceAuthority()
        // What a user picking in the panel produces: the grant is on the file
        // they clicked, so their click is what the import has to act on.
        let picked = URL(fileURLWithPath: "/Users/somebody/Desktop/Picked.kernova")
        authority.substitute = picked
        let transport = makeTransport(over: double, authority: authority)

        let response = try await transport.send(
            .importVM(path: "/Users/somebody/Desktop/Named.kernova"))

        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        #expect(summary.name == "Picked")
        #expect(
            authority.requestedURLs.map(\.path)
                == ["/Users/somebody/Desktop/Named.kernova"])
        #expect(double.importURLs == [picked])
    }

    @Test("An import nobody granted comes back as the authority's refusal, importing nothing")
    func importRefusedByTheAuthorityCrossesTheWire() async throws {
        let double = MockVMCommanding()
        let authority = MockImportSourceAuthority()
        authority.error = CommandError.operationFailed(
            verb: .importVM,
            message: "Kernova was not given permission to read \u{201C}Named.kernova\u{201D}.")
        let transport = makeTransport(over: double, authority: authority)

        let response = try await transport.send(
            .importVM(path: "/Users/somebody/Desktop/Named.kernova"))

        guard case .operationFailed(let verb, _, let message, _)? = response.failure else {
            Issue.record("expected an operation failure, got \(String(describing: response.failure))")
            return
        }
        #expect(verb == .importVM)
        #expect(message.contains("was not given permission"))
        #expect(double.importURLs.isEmpty)
    }

    // MARK: - Preparing Copies

    @Test("A wait on a VM that is not copying answers at once with its row")
    func awaitPreparingOnASettledVMAnswersAtOnce() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Settled")

        let response = try await harness.transport.send(.awaitPreparing(.id(instance.id)))

        #expect(
            response.result
                == .summary(
                    VMSummary(
                        id: instance.id, name: "Settled", status: "stopped", ipAddress: .unavailable)))
    }

    @Test("A wait on a clone still copying answers with the settled row")
    func awaitPreparingAnswersTheSettledRow() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        let started = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new))
        guard case .summary(let phantom) = started.result else {
            Issue.record("expected a summary, got \(started.result)")
            return
        }
        #expect(phantom.status == "preparing")

        let settled = try await harness.transport.send(.awaitPreparing(.id(phantom.id)))

        guard case .summary(let copy) = settled.result else {
            Issue.record("expected a summary, got \(settled.result)")
            return
        }
        #expect(copy.id == phantom.id)
        #expect(copy.status == "stopped")
    }

    @Test("A wait on a copy that failed answers with the copy's own failure")
    func awaitPreparingAnswersTheCopysFailure() async throws {
        let harness = makeHarness()
        let cloneError = VMStorageError.bundleAlreadyExists(URL(filePath: "/tmp/occupied.kernova"))
        harness.storage.cloneVMBundleError = cloneError
        let instance = makeInstance(in: harness, name: "Source")
        let started = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new))
        guard case .summary(let phantom) = started.result else {
            Issue.record("expected a summary, got \(started.result)")
            return
        }

        let settled = try await harness.transport.send(.awaitPreparing(.id(phantom.id)))

        guard case .operationFailed(let verb, _, let message, _)? = settled.failure else {
            Issue.record("expected an operation failure, got \(String(describing: settled.failure))")
            return
        }
        // The copy's own failure, verb included — not one this wait invented.
        #expect(verb == .clone)
        #expect(message == cloneError.localizedDescription)
    }

    @Test("A wait that lands after the failed copy's row is gone still answers with its failure")
    func awaitPreparingAfterTheFailedRowIsGone() async throws {
        let harness = makeHarness()
        let cloneError = VMStorageError.bundleAlreadyExists(URL(filePath: "/tmp/occupied.kernova"))
        harness.storage.cloneVMBundleError = cloneError
        let instance = makeInstance(in: harness, name: "Source")
        let started = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new))
        guard case .summary(let phantom) = started.result else {
            Issue.record("expected a summary, got \(started.result)")
            return
        }
        // The wire's second round trip can land after the copy has settled, and
        // a failed copy evicts its row — so the wait is driven here from a
        // library that has already forgotten the identifier it names.
        guard
            let task = harness.library.instances.first(where: { $0.id == phantom.id })?
                .preparingState?.task
        else {
            Issue.record("expected the clone's row to be preparing")
            return
        }
        await task.value
        #expect(!harness.library.instances.contains { $0.id == phantom.id })

        let settled = try await harness.transport.send(.awaitPreparing(.id(phantom.id)))

        guard case .operationFailed(let verb, _, let message, _)? = settled.failure else {
            Issue.record("expected an operation failure, got \(String(describing: settled.failure))")
            return
        }
        #expect(verb == .clone)
        #expect(message == cloneError.localizedDescription)
    }

    @Test("A wait on a cancelled copy answers that it was cancelled")
    func awaitPreparingOnACancelledCopy() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        let started = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new))
        guard case .summary(let phantom) = started.result else {
            Issue.record("expected a summary, got \(started.result)")
            return
        }
        // Before the copy task has had a turn, so the cancel is what the settle
        // finds rather than a race with it.
        try harness.core.cancelPreparing(.id(phantom.id), confirmed: true)

        let settled = try await harness.transport.send(.awaitPreparing(.id(phantom.id)))

        guard case .operationFailed(let verb, _, let message, _)? = settled.failure else {
            Issue.record("expected an operation failure, got \(String(describing: settled.failure))")
            return
        }
        #expect(verb == .awaitPreparing)
        #expect(message == "The clone was cancelled.")
        #expect(!harness.library.instances.contains { $0.id == phantom.id })
    }

    // MARK: - Events

    @Test("A clone's settling crosses the wire as an event")
    func cloneSettlingCrossesTheWireAsAnEvent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        var events = harness.transport.router.eventResponses().makeAsyncIterator()

        let response = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new))
        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        let phantom = try #require(harness.library.instances.first { $0.id == summary.id })
        await phantom.preparingState?.task.value

        var sawSettled = false
        while let event = await events.next() {
            if case .event(.statusChanged(let id, _, let from, let to)) = event.result,
                id == phantom.id, from == "preparing"
            {
                #expect(to == "stopped")
                sawSettled = true
                break
            }
        }
        #expect(sawSettled)
    }

    @Test("A clone whose copy fails crosses the wire as a failure event")
    func cloneFailureCrossesTheWireAsAnEvent() async throws {
        let harness = makeHarness()
        harness.storage.cloneVMBundleError = VMStorageError.bundleAlreadyExists(URL(filePath: "/tmp/occupied.kernova"))
        let instance = makeInstance(in: harness, name: "Source")
        var events = harness.transport.router.eventResponses().makeAsyncIterator()

        let response = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new))
        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        let phantom = try #require(harness.library.instances.first { $0.id == summary.id })
        await phantom.preparingState?.task.value

        var sawFailure = false
        while let event = await events.next() {
            if case .event(.failure(let id, _, _)) = event.result, id == phantom.id {
                sawFailure = true
                break
            }
        }
        #expect(sawFailure)
    }

    // MARK: - Envelope

    @Test("Bytes that are not a request are refused before any verb runs")
    func undecodableBytesAreRefused() async throws {
        let harness = makeHarness()
        makeInstance(in: harness)

        let response = try await harness.transport.sendRaw(Data("not a request".utf8))

        guard case .refused(.undecodableRequest) = response.result else {
            Issue.record("expected an undecodable-request refusal, got \(response.result)")
            return
        }
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A peer speaking another version of the vocabulary is refused")
    func foreignProtocolVersionIsRefused() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        var request = VMCommandRequest(verb: .start(.id(instance.id), recovery: false, presentation: .surface))
        request.protocolVersion = VMCommandRequest.currentProtocolVersion + 1

        let response = try await harness.transport.sendRaw(try JSONEncoder().encode(request))

        #expect(
            response.result
                == .refused(
                    .unsupportedProtocolVersion(
                        peer: VMCommandRequest.currentProtocolVersion + 1,
                        expected: VMCommandRequest.currentProtocolVersion)))
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A reveal crosses the wire onto the facade's own verb")
    func revealCrossesTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "stopped", ipAddress: .unavailable)
        double.library = [summary]
        let transport = makeTransport(over: double)

        #expect(try await transport.send(.reveal(.id(summary.id))).result == .ok)

        #expect(double.revealSelectors == [.id(summary.id)])
        #expect(double.openSelectors.isEmpty)
    }

    @Test("A Finder reveal crosses the wire onto the hook that opens the Finder")
    func showInFinderCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Filed")
        var revealed: [UUID] = []
        var surfaced: [UUID] = []
        harness.core.revealInFinder = { revealed.append($0.id) }
        harness.core.surfaceDisplay = { surfaced.append($0.id) }

        #expect(try await harness.transport.send(.showInFinder(.id(instance.id))).result == .ok)

        #expect(revealed == [instance.id])
        #expect(surfaced.isEmpty)
    }

    @Test("A Finder reveal of a bundle still being written is refused")
    func showInFinderRefusesAPreparingVM() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Copying")
        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: Task {})
        var revealed: [UUID] = []
        harness.core.revealInFinder = { revealed.append($0.id) }

        let response = try await harness.transport.send(.showInFinder(.id(instance.id)))

        // The bundle is under a hidden staging path until the copy publishes it,
        // so there is nothing at `bundleURL` for the Finder to select yet.
        #expect(
            response.failure
                == .busy(
                    vm: VMSummary(
                        id: instance.id, name: "Copying", status: "preparing", ipAddress: .unavailable),
                    operation: "import"))
        #expect(revealed.isEmpty)
        instance.preparingState = nil
    }

    @Test("A quit crosses the wire once, and is answered before anything acts on it")
    func quitCrossesTheWire() async throws {
        // Against the double rather than the core: the core's quit fires the
        // adapter hook that takes the process down, which no test may reach.
        let double = MockVMCommanding()
        let transport = makeTransport(over: double)

        #expect(try await transport.send(.quit).result == .ok)

        #expect(double.quitCallCount == 1)
    }

    @Test("The router drives anything that speaks the facade, not just the core")
    func routerDependsOnTheFacadeAlone() async throws {
        // Compiling at all is the assertion: the router takes `any VMCommanding`,
        // so a double with no library, no lifecycle coordinator and no VM behind
        // it answers the same envelope the core does.
        let double = MockVMCommanding()
        double.library = [VMSummary(id: UUID(), name: "Stub", status: "stopped", ipAddress: .unavailable)]
        double.pauseError = CommandError.unsupported(capability: "pausing")
        let transport = makeTransport(over: double)

        let listed = try await transport.send(.list)
        #expect(listed.result == .summaries(double.library))

        let refused = try await transport.send(.pause(.name("Anything")))
        #expect(refused.failure == .unsupported(capability: "pausing"))
    }
}
