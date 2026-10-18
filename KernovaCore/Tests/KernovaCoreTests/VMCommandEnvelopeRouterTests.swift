import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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
@Suite("VM Command Envelope Router Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandEnvelopeRouterTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandEnvelopeRouterTests")

    @MainActor
    private struct Harness {
        let wired: WiredCommandCore
        let transport: TestTransport

        var core: VMCommandCore { wired.core }
        var library: VMLibrary { wired.library }
        var storage: MockVMStorageService { wired.storage }
        var snapshots: MockVMBundleMachineFiles { wired.machineFiles }
        var authority: MockSandboxSourceAuthority { wired.authority }
    }

    private func makeTransport(over core: VMCommandCore) -> TestTransport {
        TestTransport(router: VMCommandEnvelopeRouter(commands: core))
    }

    private func makeHarness(
        installService: any MacOSInstallProviding = MockMacOSInstallService(),
        virtualization: any VirtualizationProviding = MockVirtualizationService(),
        diskImages: MockDiskImageService = MockDiskImageService(),
        usbAccessoryService: MockUSBAccessoryService? = nil,
        clock: any EngineClock = makePlatformEngineClock()
    ) -> Harness {
        let wired = WiredCommandCore(
            virtualization: virtualization, installService: installService,
            diskImages: diskImages, usbAccessoryService: usbAccessoryService,
            preferences: preferences, clock: clock)
        return Harness(wired: wired, transport: makeTransport(over: wired.core))
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Wired", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        harness.wired.register(name: name, phase: phase, guestOS: guestOS, mutate: mutate)
    }

    private func externalPath(_ suffix: String) -> String {
        scratch.url
            .appendingPathComponent("\(UUID().uuidString)-\(suffix)")
            .path(percentEncoded: false)
    }

    // MARK: - Reads

    @Test("A listing crosses the wire as summaries")
    func listCrossesTheWire() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "First")
        makeInstance(in: harness, name: "Second", phase: .running(sessionID: UUID()))

        let response = try await harness.transport.send(.list())

        guard case .summaries(let summaries) = response.result else {
            Issue.record("expected summaries, got \(response.result)")
            return
        }
        #expect(summaries.map(\.name) == ["First", "Second"])
        #expect(summaries.map(\.status) == ["stopped", "running"])
    }

    @Test("A filtered listing and the groups cross the wire, and an unknown group is refused")
    func filteredListAndGroupsCrossTheWire() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "First")
        makeInstance(in: harness, name: "Second", phase: .running(sessionID: UUID()))
        let running = try harness.library.organization.createSmartGroup(
            named: "Running", filter: VMLibraryFilter(states: [.running]))

        let listed = try await harness.transport.send(
            .list(VMListQuery(groups: [VMGroupReference(.smartGroup, named: "running")], sort: .name)))
        guard case .summaries(let summaries) = listed.result else {
            Issue.record("expected summaries, got \(listed.result)")
            return
        }
        #expect(summaries.map(\.name) == ["Second"])

        let grouped = try await harness.transport.send(.groups)
        guard case .groups(let groups) = grouped.result else {
            Issue.record("expected groups, got \(grouped.result)")
            return
        }
        #expect(groups.map(\.id) == [running.id])
        #expect(groups.first?.members.map(\.name) == ["Second"])

        let unknown = try await harness.transport.send(
            .list(VMListQuery(groups: [VMGroupReference(.smartGroup, named: "Nope")])))
        #expect(unknown.failure == .itemNotFoundOnHost(item: "smart group named \u{201C}Nope\u{201D}"))
    }

    @Test("A request in the vocabulary before MAC address step routes is refused as another version")
    func requestOfThePreMACRouteVocabularyIsRefused() async throws {
        let harness = makeHarness()
        let request = Data(#"{"protocolVersion":13,"verb":{"list":{}}}"#.utf8)

        let response = try await harness.transport.sendRaw(request)

        #expect(VMCommandRequest.currentProtocolVersion == 14)
        #expect(
            response.result
                == .refused(.unsupportedProtocolVersion(peer: 13, expected: VMCommandRequest.currentProtocolVersion)))
    }

    @Test("A group action crosses the wire as one request answered by one report, and an unknown group is refused")
    func groupActionCrossesTheWire() async throws {
        let virtualization = MockVirtualizationService()
        let harness = makeHarness(virtualization: virtualization)
        let stopped = makeInstance(in: harness, name: "Stopped")
        let running = makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        let lab = try harness.library.organization.createFolder(named: "Lab", members: [running.id, stopped.id])

        let response = try await harness.transport.send(
            .groupAction(.start, group: VMGroupReference(.folder, named: "lab")))

        guard case .groupAction(let report) = response.result else {
            Issue.record("expected a group action report, got \(response.result)")
            return
        }
        #expect(report.action == .start)
        #expect(report.groupID == lab.id)
        #expect(report.groupName == "Lab")
        #expect(report.groupKind == .folder)
        #expect(report.results.map(\.vm.name) == ["Running", "Stopped"])
        #expect(report.results.map(\.outcome) == [.passedOver(reason: .state), .done(verb: .start)])
        #expect(report.results.map(\.vm.status) == ["running", "running"])

        let unknown = try await harness.transport.send(
            .groupAction(.stop, group: VMGroupReference(.smartGroup, named: "Nope")))
        #expect(unknown.failure == .itemNotFoundOnHost(item: "smart group named \u{201C}Nope\u{201D}"))
        #expect(virtualization.stopCallCount == 0)
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
    func snapshotSizesCrossTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Measured")
        let snapshot = VMSnapshot(name: "Clean install", macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        let size = SnapshotSize(bytes: 12_884_901_888, privateBytes: 1_073_741_824)
        harness.snapshots.setSize(size, for: snapshot.id)

        let response = try await harness.transport.send(.snapshotSizes(.id(instance.id)))

        #expect(response.result == .snapshotSizes([snapshot.id: size]))
    }

    @Test("A VM's shares cross the wire as their own listing, addressed by identifier")
    func theShareListingCrossesTheWire() async throws {
        let harness = makeHarness()
        let named = makeInstance(in: harness, name: "Stub") {
            $0.sharedDirectories = [SharedDirectory(path: "/Users/somebody/Sites", readOnly: true)]
        }
        makeInstance(in: harness, name: "Stub") {
            $0.sharedDirectories = [SharedDirectory(path: "/Users/somebody/Elsewhere")]
        }

        let listedShares = try await harness.transport.send(.sharedDirectories(.id(named.id))).result

        #expect(
            listedShares
                == .sharedDirectories([SharedDirectorySummary(path: "/Users/somebody/Sites", readOnly: true)]))
    }

    @Test("Both USB listings and the edit cross the wire as their own requests")
    func theUSBVerbsCrossTheWire() async throws {
        let accessories = MockUSBAccessoryService()
        let harness = makeHarness(usbAccessoryService: accessories)
        let instance = makeInstance(in: harness, name: "Stub", phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        let held = MockUSBAccessoryService.accessory(registryID: 4_294_967_296)
        let free = MockUSBAccessoryService.accessory(registryID: 12, vendorID: 0x05AC, productID: 0x12A8)
        accessories.accessories = [held, free]
        let deviceID = UUID()
        accessories.nextDeviceID = deviceID
        let selector = VMSelector.id(instance.id)

        let attached = try await harness.transport.send(
            .editUSBAccessory(selector, .attach(accessory: held.registryID))
        ).result
        #expect(attached == .ok)
        #expect(accessories.attachedRegistryIDs == [held.registryID])

        // Both listings answer in one payload shape, so a client reads what a
        // guest holds and what nothing holds the same way.
        let listedHeld = try await harness.transport.send(.usbAccessories(selector)).result
        guard case .usbAccessories(let heldSummaries) = listedHeld else {
            Issue.record("expected the guest's accessories, got \(listedHeld)")
            return
        }
        #expect(heldSummaries.map(\.registryID) == [held.registryID])
        #expect(heldSummaries.map(\.deviceID) == [deviceID])
        let listedFree = try await harness.transport.send(.availableUSBAccessories).result
        guard case .usbAccessories(let freeSummaries) = listedFree else {
            Issue.record("expected the available accessories, got \(listedFree)")
            return
        }
        #expect(freeSummaries.map(\.registryID) == [free.registryID])
        #expect(freeSummaries.map(\.deviceID) == [nil])

        let detached = try await harness.transport.send(
            .editUSBAccessory(selector, .detach(device: deviceID))
        ).result
        #expect(detached == .ok)
        #expect(accessories.detachedDeviceIDs == [deviceID])
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    @Test("The remembered-accessory verbs cross the wire, one of them naming no machine")
    func theUSBPairingVerbsCrossTheWire() async throws {
        let accessories = MockUSBAccessoryService()
        let harness = makeHarness(usbAccessoryService: accessories)
        let first = makeInstance(in: harness, name: "First", phase: .running(sessionID: UUID()))
        let second = makeInstance(in: harness, name: "Second", phase: .running(sessionID: UUID()))
        let firstAccessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "AAA")
        let secondAccessory = MockUSBAccessoryService.accessory(registryID: 2, serial: "BBB")
        for (instance, accessory) in [(first, firstAccessory), (second, secondAccessory)] {
            instance.beginSessionContextForTesting()
            accessories.accessories.append(accessory)
            try await harness.core.attachUSBAccessory(.id(instance.id), accessory: accessory.registryID)
        }
        let key = try #require(firstAccessory.identity?.key)

        // The listing addresses no machine when the caller named none: a key
        // names at most one VM, so "which" is the answer being read off.
        let everyMachine = try await harness.transport.send(.usbPairings(nil)).result
        guard case .usbPairings(let everyPairing) = everyMachine else {
            Issue.record("expected the library's pairings, got \(everyMachine)")
            return
        }
        #expect(everyPairing.map(\.vm) == ["First", "Second"])
        let oneMachine = try await harness.transport.send(.usbPairings(.id(first.id))).result
        guard case .usbPairings(let firstPairings) = oneMachine else {
            Issue.record("expected one machine's pairings, got \(oneMachine)")
            return
        }
        #expect(firstPairings.map(\.key) == [key])

        let forgotten = try await harness.transport.send(.forgetUSBPairing(.id(first.id), key: key)).result
        #expect(forgotten == .ok)
        #expect(first.usbPairings.isEmpty)
        #expect(second.usbPairings.pairings.count == 1)
    }

    @Test("A listing the core refuses crosses the wire as that refusal, not as an empty list")
    func aRefusedListingCrossesTheWire() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "Stub") {
            $0.sharedDirectories = [SharedDirectory(path: "/Users/somebody/Sites")]
        }

        let refusedShares = try await harness.transport.send(.sharedDirectories(.name("Typo"))).result

        #expect(refusedShares == .failure(.notFound(selector: .name("Typo"))))
    }

    // MARK: - Verbs

    @Test("A start crosses the wire and reaches the service")
    func startCrossesTheWire() async throws {
        let virtualization = MockVirtualizationService()
        let harness = makeHarness(virtualization: virtualization)
        let instance = makeInstance(in: harness)

        let response = try await harness.transport.send(
            .start(.id(instance.id), recovery: false, consent: .none))

        #expect(response.result == .ok)
        #expect(virtualization.startCallCount == 1)
    }

    @Test("A stop deadline crosses the wire and comes back as a timeout failure")
    func stopDeadlineCrossesTheWire() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let harness = makeHarness(virtualization: virtualization, clock: TestEngineClock())
        let instance = makeInstance(
            in: harness, name: "Stubborn", phase: .running(sessionID: UUID()))

        let response = try await harness.transport.send(
            .stop(.id(instance.id), disposition: .graceful, consent: .none, timeout: 60))

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
            .start(.id(instance.id), recovery: false, consent: .none))

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
            .delete(.id(instance.id), permanently: false, alsoRemoving: [], consent: .none))

        guard case .confirmationRequired(let prompt)? = refused.failure else {
            Issue.record("expected a consent refusal, got \(String(describing: refused.failure))")
            return
        }
        #expect(prompt.kind == .deleteVM)
        #expect(prompt.confirmTitle == "Move to Trash")
        #expect(prompt.dismissTitle == "Cancel")
        #expect(harness.library.instances.count == 1)
        #expect(harness.storage.deleteVMBundleCallCount == 0)

        let confirmed = try await harness.transport.send(
            .delete(.id(instance.id), permanently: false, alsoRemoving: [], consent: .all))

        #expect(confirmed.result == .ok)
        #expect(harness.library.instances.isEmpty)
    }

    @Test("A failure that names its own heading crosses the wire carrying it")
    func operationFailureTitleCrossesTheWire() async throws {
        let virtualization = MockVirtualizationService()
        let harness = makeHarness(virtualization: virtualization)
        virtualization.startError = NSError(
            domain: VirtualizationFailure.Framework.errorDomain,
            code: VirtualizationFailure.Framework.Code.virtualMachineLimitExceeded.rawValue)
        let instance = makeInstance(in: harness, name: "Capped")

        let response = try await harness.transport.send(
            .start(.id(instance.id), recovery: false, consent: .none))

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
            .cancelGuestSetup(.id(instance.id), consent: .none))

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
            .cancelGuestSetup(.id(instance.id), consent: .all))

        #expect(response.result == .ok)
        for await _ in cancelStream.stream { break }
    }

    @Test("Cancelling with nothing in flight refuses, and the verb is not offered")
    func cancelGuestSetupWithNothingInFlightRefuses() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .stopped)

        let response = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), consent: .all))

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
            .start(.id(instance.id), recovery: false, consent: .none))
        #expect(started.result == .ok)
        for await _ in installService.installStartedStream { break }

        // The gate covers exactly the setup phase: while the install pipeline
        // is still running, cancelGuestSetup is offered and cancelling it works.
        let firstCancel = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), consent: .all))
        #expect(firstCancel.result == .ok)

        // Drain the setup operation before asserting or firing the second
        // cancel: until its ending commits, the operation still holds the VM
        // and a cancel legitimately still answers `.ok`.
        await instance.setupOperationTask?.value

        #expect(instance.status == .initialBoot)
        #expect(instance.configuration.installContext != nil)

        let secondCancel = try await harness.transport.send(
            .cancelGuestSetup(.id(instance.id), consent: .all))
        guard case .invalidState? = secondCancel.failure else {
            Issue.record("expected an invalid state, got \(String(describing: secondCancel.failure))")
            return
        }
    }

    @Test("The cancelGuestSetup gate clears before the chained auto-boot, not after it")
    func cancelGuestSetupGateClosesBeforeAutoBoot() async throws {
        let virtualization = SuspendingMockVirtualizationService()
        let harness = makeHarness(virtualization: virtualization)
        let transport = harness.transport

        let instance = harness.library.registerFixture(
            name: "Installing", guestOS: .macOS, phase: .initialBoot, preferences: preferences
        ) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }

        let started = try await transport.send(
            .start(.id(instance.id), recovery: false, consent: .none))
        #expect(started.result == .ok)

        // The install completes synchronously (`MockMacOSInstallService` has no
        // suspension), so by the time the chained auto-boot reaches the
        // suspending virtualization service's `start`, the setup phase is over
        // and the gate should already be closed.
        await virtualization.waitUntilSuspended()

        let response = try await transport.send(.cancelGuestSetup(.id(instance.id), consent: .all))
        guard case .invalidState(_, _, let allowed, _)? = response.failure else {
            Issue.record("expected an invalid state, got \(String(describing: response.failure))")
            return
        }
        #expect(!allowed.contains(.cancelGuestSetup))

        virtualization.resumeSuspended()
    }

    // MARK: - Attachments

    @Test("Each storage-disk edit crosses the wire onto its own verb")
    func storageDiskEditsCrossTheWire() async throws {
        let diskImages = MockDiskImageService()
        let harness = makeHarness(diskImages: diskImages)
        let externalPath = externalPath("external.img")
        let main = StorageDisk(path: "AdditionalDisks/main.asif", label: "Main", isInternal: true)
        let target = StorageDisk(path: "AdditionalDisks/target.asif", label: "Target", isInternal: true)
        let external = StorageDisk(path: externalPath, label: "External", isInternal: false)
        let instance = makeInstance(in: harness, name: "Stub") { $0.storageDisks = [main, target, external] }
        let selector = VMSelector.id(instance.id)

        for edit: StorageDiskEdit in [
            .create(sizeInGB: 32),
            .remove(disk: external.id, trashFile: true, consent: .all),
            .rename(disk: target.id, newLabel: "Scratch"),
            .setNotes(disk: target.id, notes: "the build cache"),
            .setReadOnly(disk: target.id, readOnly: true),
            .reorder(order: [target.id]),
        ] {
            #expect(try await harness.transport.send(.editStorageDisk(selector, edit)).result == .ok)
        }

        let disks = instance.configuration.storageDisks ?? []
        #expect(diskImages.lastCreatedSizeInGB == 32)
        #expect(disks.map(\.label) == ["Scratch", "Main", "32 GB Disk"])
        #expect(harness.wired.fileSystem.trashedURLs == [URL(fileURLWithPath: externalPath)])
        let edited = try #require(disks.first { $0.id == target.id })
        #expect(edited.notes == "the build cache")
        #expect(edited.readOnly)
    }

    @Test("Each removable-media edit crosses the wire onto its own verb")
    func removableMediaEditsCrossTheWire() async throws {
        let harness = makeHarness()
        let kept = RemovableMediaItem(path: externalPath("kept.iso"), readOnly: true, label: "Kept")
        let ejected = RemovableMediaItem(path: externalPath("ejected.iso"), readOnly: true, label: "Ejected")
        let target = RemovableMediaItem(path: externalPath("target.iso"), readOnly: true, label: "Target")
        let instance = makeInstance(in: harness, name: "Stub") { $0.removableMedia = [kept, ejected, target] }
        let selector = VMSelector.id(instance.id)

        for edit: RemovableMediaEdit in [
            .remove(item: kept.id, trashFile: false, consent: .all),
            .eject(item: ejected.id),
            .rename(item: target.id, newLabel: "Installer"),
            .setNotes(item: target.id, notes: "from the mirror"),
            .setReadOnly(item: target.id, readOnly: false),
        ] {
            #expect(try await harness.transport.send(.editRemovableMedia(selector, edit)).result == .ok)
        }

        let media = instance.configuration.removableMedia ?? []
        #expect(media.map(\.id) == [target.id])
        #expect(media.first?.label == "Installer")
        #expect(media.first?.notes == "from the mirror")
        #expect(media.first?.readOnly == false)
        #expect(harness.wired.fileSystem.trashedURLs.isEmpty)
    }

    @Test("Each shared-directory edit crosses the wire onto its own verb")
    func sharedDirectoryEditsCrossTheWire() async throws {
        let harness = makeHarness()
        let going = SharedDirectory(path: externalPath("going"))
        let flipped = SharedDirectory(path: externalPath("flipped"))
        let instance = makeInstance(in: harness, name: "Stub") { $0.sharedDirectories = [going, flipped] }
        let selector = VMSelector.id(instance.id)

        for edit: SharedDirectoryEdit in [
            .remove(directory: going.id),
            .setReadOnly(directory: flipped.id, readOnly: true),
        ] {
            #expect(try await harness.transport.send(.editSharedDirectory(selector, edit)).result == .ok)
        }

        #expect(instance.configuration.sharedDirectories?.map(\.id) == [flipped.id])
        #expect(instance.configuration.sharedDirectories?.map(\.readOnly) == [true])
    }

    @Test("Both guest-agent-disk edits cross the wire")
    func guestAgentDiskEditsCrossTheWire() async throws {
        let installerPath = try #require(BundledGuestAgent.testing.installerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Stub", phase: .running(sessionID: UUID()), guestOS: .macOS)
        let selector = VMSelector.id(instance.id)

        #expect(try await harness.transport.send(.guestAgentDisk(selector, .mount)).result == .ok)
        #expect(instance.configuration.removableMedia?.map(\.path) == [installerPath])

        #expect(try await harness.transport.send(.guestAgentDisk(selector, .unmount)).result == .ok)
        #expect(instance.configuration.removableMedia == nil)
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
        let path = scratch.url
            .appendingPathComponent("\(UUID().uuidString)-external.img")
            .path(percentEncoded: false)
        let disk = StorageDisk(path: path, label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk, keeper] }

        let refused = try await harness.transport.send(
            .editStorageDisk(
                .id(instance.id), .remove(disk: disk.id, trashFile: true, consent: .none)))
        guard case .confirmationRequired(let prompt) = try #require(refused.failure) else {
            Issue.record("expected a consent refusal, got \(String(describing: refused.failure))")
            return
        }
        #expect(prompt.kind == .removeAttachment)
        #expect(instance.configuration.storageDisks?.count == 2)

        let confirmed = try await harness.transport.send(
            .editStorageDisk(
                .id(instance.id), .remove(disk: disk.id, trashFile: true, consent: .all)))
        #expect(confirmed.result == .ok)
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
    }

    // MARK: - Import

    @Test("An import crosses the wire as the path the client named, answered at once")
    func importCrossesTheWire() async throws {
        let harness = makeHarness()
        let source = try scratch.importSource(name: "Named").url
        let path = source.path(percentEncoded: false)

        let response = try await harness.transport.send(.importVM(path: path, waitForOutcome: false))

        guard case .summary(let summary) = response.result else {
            Issue.record("expected a summary, got \(response.result)")
            return
        }
        #expect(summary.name == "Named")
        // Unwaited: the answer is the row still being copied in.
        #expect(summary.status == VMStatus.preparingWireName)
        // The grant the path needs belongs to the verb, not to the wire: the
        // router hands the string over untouched.
        #expect(harness.authority.requests.map(\.source) == [.vmBundle])
        #expect(harness.authority.requestedURLs.map { $0.path(percentEncoded: false) } == [path])
        let arrival = try #require(harness.library.arrivals.first { $0.id == summary.id })
        await arrival.settle()
    }

    @Test("An import nobody granted comes back as the verb's own refusal")
    func importRefusalCrossesTheWire() async throws {
        let harness = makeHarness()
        harness.authority.error = CommandError.operationFailed(
            verb: .importVM,
            message: "Kernova was not given permission to read \u{201C}Named.kernova\u{201D}.")

        let response = try await harness.transport.send(
            .importVM(path: "/Users/somebody/Desktop/Named.kernova", waitForOutcome: false))

        guard case .operationFailed(let verb, _, let message, _)? = response.failure else {
            Issue.record("expected an operation failure, got \(String(describing: response.failure))")
            return
        }
        #expect(verb == .importVM)
        #expect(message.contains("was not given permission"))
        #expect(harness.library.entries.isEmpty)
    }

    // MARK: - Arrivals

    @Test("A waited clone answers the row it settled into")
    func waitedCloneAnswersTheSettledRow() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")

        let response = try await harness.transport.send(
            .clone(.id(instance.id), outcome: .newMachine, waitForOutcome: true))

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
        harness.storage.setCloneVMBundleError(CocoaError(.fileWriteOutOfSpace))

        let response = try await harness.transport.send(
            .clone(.id(instance.id), outcome: .newMachine, waitForOutcome: true))

        guard case .operationFailed(let verb, _, _, _)? = response.failure else {
            Issue.record("expected an operation failure, got \(String(describing: response.failure))")
            return
        }
        #expect(verb == .clone)
        #expect(harness.wired.failures.isEmpty)
        #expect(harness.library.entries.map(\.id) == [instance.id])
    }

    @Test("An unwaited clone answers its preparing row at once")
    func unwaitedCloneAnswersThePreparingRow() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Source")
        let hold = DispatchSemaphore(value: 0)
        harness.storage.setCloneHold(hold)
        defer { hold.signal() }

        let response = try await harness.transport.send(
            .clone(.id(instance.id), outcome: .newMachine, waitForOutcome: false))

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
        harness.storage.setCloneHold(hold)
        let waiting = Task {
            try await harness.transport.send(
                .clone(.id(instance.id), outcome: .newMachine, waitForOutcome: true))
        }
        // Held inside the copy, so the cancel is what the settle finds rather
        // than a race with it.
        try await harness.storage.cloneEntered.wait { harness.storage.cloneVMBundleCallCount == 1 }
        let arrival = try #require(harness.library.arrivals.first)

        try harness.core.cancelPreparing(.id(arrival.id), consent: .all)
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
            .clone(.id(instance.id), outcome: .newMachine, waitForOutcome: false))
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
        harness.storage.setCloneVMBundleError(
            VMStorageError.bundleAlreadyExists(URL(filePath: "/tmp/occupied.kernova")))
        let instance = makeInstance(in: harness, name: "Source")
        var events = harness.transport.router.eventResponses().makeAsyncIterator()

        let response = try await harness.transport.send(
            .clone(.id(instance.id), outcome: .newMachine, waitForOutcome: false))
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
        let virtualization = MockVirtualizationService()
        let harness = makeHarness(virtualization: virtualization)
        makeInstance(in: harness)

        let response = try await harness.transport.sendRaw(Data("not a request".utf8))

        guard case .refused(.undecodableRequest) = response.result else {
            Issue.record("expected an undecodable-request refusal, got \(response.result)")
            return
        }
        #expect(virtualization.startCallCount == 0)
    }

    @Test("A peer speaking another version of the vocabulary is refused")
    func foreignProtocolVersionIsRefused() async throws {
        let virtualization = MockVirtualizationService()
        let harness = makeHarness(virtualization: virtualization)
        let instance = makeInstance(in: harness)
        var request = VMCommandRequest(
            verb: .start(.id(instance.id), recovery: false, consent: .none))
        request.protocolVersion = VMCommandRequest.currentProtocolVersion + 1

        let response = try await harness.transport.sendRaw(try JSONEncoder().encode(request))

        #expect(
            response.result
                == .refused(
                    .unsupportedProtocolVersion(
                        peer: VMCommandRequest.currentProtocolVersion + 1,
                        expected: VMCommandRequest.currentProtocolVersion)))
        #expect(virtualization.startCallCount == 0)
    }

    @Test("A reveal crosses the wire onto the core's own verb")
    func revealCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Stub")

        #expect(try await harness.transport.send(.reveal(.id(instance.id))).result == .ok)

        // A stopped VM has no display to surface, so the reveal lands on its row.
        #expect(harness.wired.revealedInLibrary == [instance.id])
        #expect(harness.wired.surfacedDisplays.isEmpty)
    }

    @Test("A Finder reveal crosses the wire onto the hook that opens the Finder")
    func showInFinderCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Filed")

        #expect(try await harness.transport.send(.showInFinder(.id(instance.id))).result == .ok)

        #expect(harness.wired.revealedInFinder == [instance.id])
        #expect(harness.wired.surfacedDisplays.isEmpty)
    }

    @Test("A Finder reveal of a bundle still being written is refused")
    func showInFinderRefusesAnArrival() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(named: "Copying", gate: gate)

        let response = try await harness.transport.send(.showInFinder(.id(arrival.id)))

        // The bundle is under a hidden staging path until the copy publishes it,
        // so there is nothing at its destination for the Finder to select yet.
        #expect(
            response.failure
                == .busy(
                    vm: VMSummary(
                        id: arrival.id, name: "Copying", status: "preparing", ipAddress: .unavailable,
                        heldByAnotherCopy: false),
                    operation: "import"))
        #expect(harness.wired.revealedInFinder.isEmpty)
        gate.release()
        await arrival.settle()
    }

    @Test("A quit crosses the wire once, and is answered before anything acts on it")
    func quitCrossesTheWire() async throws {
        let harness = makeHarness()

        #expect(try await harness.transport.send(.quit).result == .ok)

        try await harness.wired.quitRequested.wait { harness.wired.quitRequests > 0 }
        #expect(harness.wired.quitRequests == 1)
    }

    // MARK: - Configuration

    @Test("The keyspace, a read and a write each cross the wire as their own payload")
    func configurationVerbsCrossTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha") {
            $0.cpuCount = 4
            $0.clipboardSharingEnabled = true
        }

        #expect(
            try await harness.transport.send(.configurationKeys).result
                == .configurationKeys(VMConfigurationKeyRegistry.keys.map(\.descriptor)))

        #expect(
            try await harness.transport.send(.configuration(.name("Alpha"), keys: ["cpus"])).result
                == .configuration([ConfigurationEntry(key: "cpus", value: "4")]))

        let assignments = [
            ConfigurationEntry(key: "cpus", value: "3"),
            ConfigurationEntry(key: "clipboard.passthrough", value: "true"),
        ]
        // The consent travels with the write: without it, the passthrough the
        // batch turns on is refused and nothing is written.
        let refused = try await harness.transport.send(
            .setConfiguration(.name("Alpha"), assignments: assignments, consent: .none))
        guard case .confirmationRequired(let prompt)? = refused.failure else {
            Issue.record("expected a consent refusal, got \(String(describing: refused.failure))")
            return
        }
        #expect(prompt.kind == .enableClipboardPassthrough)
        #expect(instance.configuration.cpuCount == 4)

        #expect(
            try await harness.transport.send(
                .setConfiguration(.name("Alpha"), assignments: assignments, consent: .all)
            ).result == .configuration(assignments))
        #expect(instance.configuration.cpuCount == 3)
        #expect(instance.configuration.clipboardPassthroughEnabled)
    }

    @Test("A configuration refusal comes back as the refusal, not as a failed operation")
    func configurationRefusalsCrossTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha") { $0.cpuCount = 4 }

        let unknown = try await harness.transport.send(
            .setConfiguration(
                .name("Alpha"), assignments: [ConfigurationEntry(key: "cpu", value: "3")],
                consent: .none))
        #expect(
            unknown.failure
                == .invalidArgument(message: "There is no setting called \u{201C}cpu\u{201D}."))

        // A key the guest cannot have is refused as unsupported.
        let inapplicable = try await harness.transport.send(
            .setConfiguration(
                .name("Alpha"), assignments: [ConfigurationEntry(key: "input.devices", value: "usb")],
                consent: .none))
        #expect(inapplicable.failure == .unsupported(capability: "the input.devices setting"))
        #expect(instance.configuration.cpuCount == 4)
    }

    @Test("A share add crosses the wire as the path the client named and its flag")
    func shareAddCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha")
        let folder = externalPath("Asked")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        #expect(
            try await harness.transport.send(
                .editSharedDirectory(.name("Alpha"), .add(path: folder, readOnly: true))
            ).result == .ok)

        // The grant the path needs belongs to the verb, not to the wire: the
        // router hands the string over untouched.
        #expect(harness.authority.requests.map(\.source) == [.sharedDirectory])
        // A URL for an existing folder spells it with a trailing separator, so
        // the paths compare as folders.
        let asked = harness.authority.requestedURLs.map {
            VMCommandCore.comparablePath($0.path(percentEncoded: false))
        }
        #expect(asked == [folder])
        #expect(instance.configuration.sharedDirectories?.map { VMCommandCore.comparablePath($0.path) } == [folder])
        #expect(instance.configuration.sharedDirectories?.map(\.readOnly) == [true])
    }

    @Test("A share nobody granted comes back as the verb's own refusal")
    func shareAddRefusalCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha")
        harness.authority.error = CommandError.operationFailed(
            verb: .editSharedDirectory, message: "Kernova was not given permission.")

        let response = try await harness.transport.send(
            .editSharedDirectory(
                .name("Alpha"), .add(path: "/Users/somebody/Asked", readOnly: false)))

        guard case .operationFailed(let verb, _, let message, _)? = response.failure else {
            Issue.record("expected an operation failure, got \(String(describing: response.failure))")
            return
        }
        #expect(verb == .editSharedDirectory)
        #expect(message == "Kernova was not given permission.")
        #expect(instance.configuration.sharedDirectories == nil)
    }

    @Test("A share removal names the folder by path")
    func shareRemovalByPathCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha") {
            $0.sharedDirectories = [SharedDirectory(path: "/Users/somebody/Sites")]
        }

        #expect(
            try await harness.transport.send(
                .editSharedDirectory(.name("Alpha"), .removePath(path: "/Users/somebody/Sites"))
            ).result == .ok)

        #expect(instance.configuration.sharedDirectories == nil)
    }
}
