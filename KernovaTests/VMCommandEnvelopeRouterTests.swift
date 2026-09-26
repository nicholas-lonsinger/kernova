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
    private let preferences = makeTestPreferences()

    private struct Harness {
        let transport: TestTransport
        let core: VMCommandCore
        let authority: MockSandboxSourceAuthority
        let library: VMLibrary
        let storage: MockVMStorageService
        let virtualization: MockVirtualizationService
        let snapshots: MockVMBundleMachineFiles
    }

    /// A transport over anything that speaks the facade.
    private func makeTransport(over commands: any VMCommanding) -> TestTransport {
        TestTransport(router: VMCommandEnvelopeRouter(commands: commands))
    }

    private func makeHarness(
        installService: any MacOSInstallProviding = MockMacOSInstallService(),
        virtualization: MockVirtualizationService = MockVirtualizationService(),
        clock: any EngineClock = makePlatformEngineClock()
    ) -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMBundleMachineFiles()
        let fileSystem = MockFileSystem()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization,
            installService: installService,
            fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage,
            machineFiles: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences)
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            diskImageService: MockDiskImageService(),
            fileSystem: fileSystem,
            preferences: preferences,
            clock: clock
        )
        let authority = MockSandboxSourceAuthority()
        core.sourceAuthority = authority
        return Harness(
            transport: makeTransport(over: core),
            core: core, authority: authority,
            library: library, storage: storage, virtualization: virtualization,
            snapshots: snapshots)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Wired", phase: VMLifecyclePhase = .stopped,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: .linux, library: harness.library,
            preferences: preferences, mutate: mutate)
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
        let snapshot = VMSnapshot(name: "Clean install", macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        harness.snapshots.setSize(12_884_901_888, for: snapshot.id)

        let response = try await harness.transport.send(.snapshotOnDiskBytes(.id(instance.id)))

        #expect(response.result == .snapshotSizes([snapshot.id: 12_884_901_888]))
    }

    @Test("A VM's shares cross the wire as their own listing")
    func theShareListingCrossesTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "stopped", ipAddress: .unavailable)
        double.library = [summary]
        let shares = [SharedDirectorySummary(path: "/Users/somebody/Sites", readOnly: true)]
        double.sharedDirectoriesByVM = [summary.id: shares]
        let transport = makeTransport(over: double)
        let selector = VMSelector.id(summary.id)

        let listedShares = try await transport.send(.sharedDirectories(selector)).result
        #expect(listedShares == .sharedDirectories(shares))

        #expect(double.sharedDirectoriesSelectors == [selector])
    }

    @Test("Both USB listings and the edit cross the wire as their own requests")
    func theUSBVerbsCrossTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "running", ipAddress: .unavailable)
        double.library = [summary]
        let held = [
            USBAccessorySummary(
                registryID: 4_294_967_296, name: "0403:6001 \u{00B7} Vendor-specific",
                vendorID: 0x0403, productID: 0x6001, deviceID: UUID())
        ]
        let free = [
            USBAccessorySummary(
                registryID: 12, name: "05ac:12a8 \u{00B7} Composite", vendorID: 0x05AC,
                productID: 0x12A8)
        ]
        double.usbAccessoriesByVM = [summary.id: held]
        double.availableUSBAccessoriesToReturn = free
        let transport = makeTransport(over: double)
        let selector = VMSelector.id(summary.id)
        let edit = USBAccessoryEdit.attach(accessory: 4_294_967_296)

        let listedHeld = try await transport.send(.usbAccessories(selector)).result
        #expect(listedHeld == .usbAccessories(held))
        // Both listings answer in one payload shape, so a client reads what a
        // guest holds and what nothing holds the same way.
        let listedFree = try await transport.send(.availableUSBAccessories).result
        #expect(listedFree == .usbAccessories(free))
        let attached = try await transport.send(.editUSBAccessory(selector, edit)).result
        #expect(attached == .ok)
        let deviceID = UUID()
        let detached = try await transport.send(
            .editUSBAccessory(selector, .detach(device: deviceID))
        ).result
        #expect(detached == .ok)

        #expect(double.usbAccessoriesSelectors == [selector])
        #expect(double.availableUSBAccessoriesCallCount == 1)
        // The router unpacks the edit onto the facade's two verbs, the way it
        // does for every other attachment family.
        #expect(double.attachUSBAccessoryCalls.map(\.selector) == [selector])
        #expect(double.attachUSBAccessoryCalls.map(\.accessory) == [4_294_967_296])
        #expect(double.detachUSBAccessoryCalls.map(\.selector) == [selector])
        #expect(double.detachUSBAccessoryCalls.map(\.device) == [deviceID])
    }

    @Test("The remembered-accessory verbs cross the wire, one of them naming no machine")
    func theUSBPairingVerbsCrossTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "stopped", ipAddress: .unavailable)
        double.library = [summary]
        let pairings = [
            USBPairingSummary(
                vm: "Stub", key: "04e8:6300:0100:0373", name: "Samsung Type-C",
                pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ]
        double.usbPairingsToReturn = pairings
        let transport = makeTransport(over: double)
        let selector = VMSelector.id(summary.id)

        let everyMachine = try await transport.send(.usbPairings(nil)).result
        #expect(everyMachine == .usbPairings(pairings))
        let oneMachine = try await transport.send(.usbPairings(selector)).result
        #expect(oneMachine == .usbPairings(pairings))
        let forgotten = try await transport.send(
            .forgetUSBPairing(selector, key: "04e8:6300:0100:0373")
        ).result
        #expect(forgotten == .ok)

        // The listing addresses no machine when the caller named none: a key
        // names at most one VM, so "which" is the answer being read off.
        #expect(double.usbPairingsSelectors == [nil, selector])
        #expect(double.forgetUSBPairingCalls.map(\.key) == ["04e8:6300:0100:0373"])
    }

    @Test("A listing the facade refuses crosses the wire as that refusal, not as an empty list")
    func aRefusedListingCrossesTheWire() async throws {
        let double = MockVMCommanding()
        let summary = VMSummary(id: UUID(), name: "Stub", status: "stopped", ipAddress: .unavailable)
        double.library = [summary]
        double.sharedDirectoriesError = CommandError.notFound(.name("Typo"))
        let transport = makeTransport(over: double)
        let selector = VMSelector.id(summary.id)

        let refusedShares = try await transport.send(.sharedDirectories(selector)).result
        #expect(refusedShares == .failure(.notFound(selector: .name("Typo"))))
    }

    // MARK: - Verbs

    @Test("A start crosses the wire and reaches the service")
    func startCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        let response = try await harness.transport.send(
            .start(.id(instance.id), recovery: false))

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
            .start(.id(instance.id), recovery: false))

        guard case .invalidState(_, let current, let allowed, _)? = response.failure else {
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
            .start(.id(instance.id), recovery: false))

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
        let instance = makeInstance(in: harness, phase: .initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        let setup = try instance.launchParkedSetup()
        instance.setupState = .macOSInstall(hasDownloadStep: false)
        defer { setup.task?.cancel() }

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
        let instance = makeInstance(in: harness, phase: .initialBoot) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        let cancelStream = AsyncStream<Void>.makeStream()
        try instance.launchParkedSetup {
            cancelStream.continuation.yield(())
            cancelStream.continuation.finish()
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

        guard case .invalidState(_, _, let allowed, _)? = response.failure else {
            Issue.record("expected an invalid state, got \(String(describing: response.failure))")
            return
        }
        #expect(!allowed.contains(.cancelGuestSetup))
    }

    @Test("A second cancel after the setup task drains refuses, and the VM stays resumable")
    func repeatedCancelGuestSetupRefusesOnceDrained() async throws {
        let installService = SuspendingMockMacOSInstallService()
        let harness = makeHarness(installService: installService)
        let instance = harness.library.registerFixture(
            name: "Installing", guestOS: .macOS, phase: .initialBoot, preferences: preferences
        ) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }

        let started = try await harness.transport.send(
            .start(.id(instance.id), recovery: false))
        #expect(started.result == .ok)
        for await _ in installService.installStartedStream { break }

        // The gate covers exactly the setup phase: while the install pipeline
        // is still running, cancelGuestSetup is offered and cancelling it works.
        let firstCancel = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), confirmed: true))
        #expect(firstCancel.result == .ok)

        // Drain the setup operation before asserting or firing the second
        // cancel: until its ending commits, the operation still holds the VM
        // and a cancel legitimately still answers `.ok`.
        await instance.setupOperationTask?.value

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
        let snapshots = MockVMBundleMachineFiles()
        let fileSystem = MockFileSystem()
        let virtualization = SuspendingMockVirtualizationService()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization,
            fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage,
            machineFiles: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(),
            fileSystem: fileSystem, preferences: preferences)
        let transport = makeTransport(over: core)

        let instance = library.registerFixture(
            name: "Installing", guestOS: .macOS, phase: .initialBoot, preferences: preferences
        ) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }

        let started = try await transport.send(.start(.id(instance.id), recovery: false))
        #expect(started.result == .ok)

        // The install completes synchronously (`MockMacOSInstallService` has no
        // suspension), so by the time the chained auto-boot reaches the
        // suspending virtualization service's `start`, the setup phase is over
        // and the gate should already be closed.
        await virtualization.waitUntilSuspended()

        let response = try await transport.send(.cancelGuestSetup(.id(instance.id), confirmed: true))
        guard case .invalidState(_, _, let allowed, _)? = response.failure else {
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
        let disk = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID())) {
            $0.storageDisks = [disk]
        }

        let response = try await harness.transport.send(
            .editStorageDisk(.id(instance.id), .rename(disk: disk.id, newLabel: "New")))

        guard case .invalidState(_, _, let allowed, _) = try #require(response.failure) else {
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
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")
            .path(percentEncoded: false)
        let disk = StorageDisk(path: path, label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk, keeper] }

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

    @Test("An import crosses the wire as the path the client named")
    func importCrossesTheWire() async throws {
        let double = MockVMCommanding()
        let transport = makeTransport(over: double)

        let response = try await transport.send(
            .importVM(path: "/Users/somebody/Desktop/Named.kernova", waitForOutcome: false))

        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        #expect(summary.name == "Named")
        #expect(
            double.importURLs.map { $0.path(percentEncoded: false) }
                == ["/Users/somebody/Desktop/Named.kernova"])
        #expect(double.importWaits == [false])
    }

    @Test("An import nobody granted comes back as the verb's own refusal")
    func importRefusalCrossesTheWire() async throws {
        let double = MockVMCommanding()
        double.importError = CommandError.operationFailed(
            verb: .importVM,
            message: "Kernova was not given permission to read \u{201C}Named.kernova\u{201D}.")
        let transport = makeTransport(over: double)

        let response = try await transport.send(
            .importVM(path: "/Users/somebody/Desktop/Named.kernova", waitForOutcome: false))

        guard case .operationFailed(let verb, _, let message, _)? = response.failure else {
            Issue.record("expected an operation failure, got \(String(describing: response.failure))")
            return
        }
        #expect(verb == .importVM)
        #expect(message.contains("was not given permission"))
    }

    // MARK: - Arrivals

    @Test("A waited clone answers the row it settled into")
    func waitedCloneAnswersTheSettledRow() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")

        let response = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new, waitForOutcome: true))

        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        #expect(summary.status == VMStatus.stopped.rawValue)
        #expect(harness.library.arrivals.isEmpty)
        #expect(Set(harness.library.instances.map(\.id)) == [instance.id, summary.id])
    }

    @Test("A waited clone whose copy fails answers that failure, and nothing is reported")
    func waitedCloneThrowsTheCopysFailure() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        harness.storage.cloneVMBundleError = CocoaError(.fileWriteOutOfSpace)
        var reported: [CommandError] = []
        harness.core.onFailure = { failure, _ in reported.append(failure) }

        let response = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new, waitForOutcome: true))

        guard case .operationFailed(let verb, _, _, _)? = response.failure else {
            Issue.record("expected an operation failure, got \(String(describing: response.failure))")
            return
        }
        #expect(verb == .clone)
        #expect(reported.isEmpty)
        #expect(harness.library.entries.map(\.id) == [instance.id])
    }

    @Test("An unwaited clone answers its preparing row at once")
    func unwaitedCloneAnswersThePreparingRow() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        let hold = DispatchSemaphore(value: 0)
        harness.storage.cloneHold = hold
        defer { hold.signal() }

        let response = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new, waitForOutcome: false))

        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        #expect(summary.status == VMStatus.preparingWireName)
        let arrival = try #require(harness.library.arrivals.first)
        #expect(arrival.id == summary.id)
        hold.signal()
        await arrival.settle()
    }

    @Test("A waited clone the user cancels answers that it was cancelled")
    func waitedCloneCancelledAnswersCancelled() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        let hold = DispatchSemaphore(value: 0)
        harness.storage.cloneHold = hold
        let waiting = Task {
            try await harness.transport.send(
                .clone(.id(instance.id), machineIdentity: .new, waitForOutcome: true))
        }
        // Held inside the copy, so the cancel is what the settle finds rather
        // than a race with it.
        try await harness.storage.cloneEntered.wait { harness.storage.cloneVMBundleCallCount == 1 }
        let arrival = try #require(harness.library.arrivals.first)

        try harness.core.cancelPreparing(.id(arrival.id), confirmed: true)
        hold.signal()
        let settled = try await waiting.value

        guard case .operationFailed(let verb, _, let message, _)? = settled.failure else {
            Issue.record("expected an operation failure, got \(String(describing: settled.failure))")
            return
        }
        #expect(verb == .clone)
        #expect(message == "The clone was cancelled.")
        #expect(!harness.library.entries.contains { $0.id == arrival.id })
    }

    // MARK: - Events

    @Test("A clone's settling crosses the wire as an event")
    func cloneSettlingCrossesTheWireAsAnEvent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        var events = harness.transport.router.eventResponses().makeAsyncIterator()

        let response = try await harness.transport.send(
            .clone(.id(instance.id), machineIdentity: .new, waitForOutcome: false))
        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        let arrival = try #require(harness.library.arrivals.first { $0.id == summary.id })
        await arrival.settle()

        var sawSettled = false
        while let event = await events.next() {
            if case .event(.statusChanged(let id, _, let from, let to)) = event.result,
                id == arrival.id, from == "preparing"
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
            .clone(.id(instance.id), machineIdentity: .new, waitForOutcome: false))
        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        let arrival = try #require(harness.library.arrivals.first { $0.id == summary.id })
        await arrival.settle()

        var sawFailure = false
        while let event = await events.next() {
            if case .event(.failure(let id, _, _)) = event.result, id == arrival.id {
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
        var request = VMCommandRequest(verb: .start(.id(instance.id), recovery: false))
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
    func showInFinderRefusesAnArrival() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(named: "Copying", gate: gate)
        var revealed: [UUID] = []
        harness.core.revealInFinder = { revealed.append($0.id) }

        let response = try await harness.transport.send(.showInFinder(.id(arrival.id)))

        // The bundle is under a hidden staging path until the copy publishes it,
        // so there is nothing at its destination for the Finder to select yet.
        #expect(
            response.failure
                == .busy(
                    vm: VMSummary(
                        id: arrival.id, name: "Copying", status: "preparing", ipAddress: .unavailable),
                    operation: "import"))
        #expect(revealed.isEmpty)
        gate.release()
        await arrival.settle()
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

    // MARK: - Configuration

    @Test("The keyspace, a read and a write each cross the wire as their own payload")
    func configurationVerbsCrossTheWire() async throws {
        let double = MockVMCommanding()
        double.configurationKeyDescriptors = [
            ConfigurationKeyDescriptor(
                name: "cpus", summary: "Virtual CPU cores.", editableWhileRunning: false)
        ]
        double.configurationEntries = [ConfigurationEntry(key: "cpus", value: "4")]
        let transport = makeTransport(over: double)

        #expect(
            try await transport.send(.configurationKeys).result
                == .configurationKeys(double.configurationKeyDescriptors))
        #expect(double.configurationKeysCallCount == 1)

        #expect(
            try await transport.send(.configuration(.name("Alpha"), keys: ["cpus"])).result
                == .configuration(double.configurationEntries))
        #expect(double.configurationCalls.map(\.keys) == [["cpus"]])

        let assignments = [ConfigurationEntry(key: "cpus", value: "3")]
        #expect(
            try await transport.send(
                .setConfiguration(.name("Alpha"), assignments: assignments, confirmed: true)
            ).result == .configuration(assignments))
        #expect(double.setConfigurationCalls.map(\.confirmed) == [true])
        #expect(double.setConfigurationCalls.map(\.assignments) == [assignments])
    }

    @Test("A configuration refusal comes back as the refusal, not as a failed operation")
    func configurationRefusalsCrossTheWire() async throws {
        let double = MockVMCommanding()
        double.setConfigurationError = CommandError.invalidArgument("There is no setting called \u{201C}cpu\u{201D}.")
        let transport = makeTransport(over: double)

        let response = try await transport.send(
            .setConfiguration(
                .name("Alpha"), assignments: [ConfigurationEntry(key: "cpu", value: "3")],
                confirmed: false))

        #expect(
            response.failure
                == .invalidArgument(message: "There is no setting called \u{201C}cpu\u{201D}."))
    }

    @Test("A share add crosses the wire as the path the client named and its flag")
    func shareAddCrossesTheWire() async throws {
        let double = MockVMCommanding()
        let transport = makeTransport(over: double)

        #expect(
            try await transport.send(
                .editSharedDirectory(
                    .name("Alpha"), .add(path: "/Users/somebody/Asked", readOnly: true))
            ).result == .ok)

        // The grant the path needs belongs to the verb, not to the wire: the
        // router hands the string over untouched.
        #expect(double.addSharedDirectoryCalls.map(\.path) == ["/Users/somebody/Asked"])
        #expect(double.addSharedDirectoryCalls.map(\.readOnly) == [true])
    }

    @Test("A share nobody granted comes back as the verb's own refusal")
    func shareAddRefusalCrossesTheWire() async throws {
        let double = MockVMCommanding()
        double.sharedDirectoryEditError = CommandError.operationFailed(
            verb: .editSharedDirectory, message: "Kernova was not given permission.")
        let transport = makeTransport(over: double)

        let response = try await transport.send(
            .editSharedDirectory(
                .name("Alpha"), .add(path: "/Users/somebody/Asked", readOnly: false)))

        #expect(response.failure != nil)
    }

    @Test("A share removal names the folder by path")
    func shareRemovalByPathCrossesTheWire() async throws {
        let double = MockVMCommanding()
        let transport = makeTransport(over: double)

        #expect(
            try await transport.send(
                .editSharedDirectory(.name("Alpha"), .removePath(path: "/Users/somebody/Sites"))
            ).result == .ok)

        #expect(double.removeSharedDirectoryPathCalls.map(\.path) == ["/Users/somebody/Sites"])
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
