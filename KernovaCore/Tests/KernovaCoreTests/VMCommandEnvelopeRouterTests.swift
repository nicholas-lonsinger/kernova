import Foundation
import KernovaCommandModel
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
        usbAccessoryPassthrough: USBAccessoryPassthrough = .unavailable(.needsEntitlement),
        clock: any EngineClock = makePlatformEngineClock()
    ) -> Harness {
        let wired = WiredCommandCore(
            virtualization: virtualization, installService: installService,
            diskImages: diskImages, usbAccessoryPassthrough: usbAccessoryPassthrough,
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

        #expect(VMCommandRequest.currentProtocolVersion == 19)
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

    @Test("A VM's storage disks cross the wire in their configured order, each measured from its image")
    func storageDisksCrossTheWireInOrder() async throws {
        let harness = makeHarness()
        let installerPath = externalPath("installer.iso")
        let installer = StorageDisk(path: installerPath, readOnly: true, label: "Installer")
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true, kind: .virtio, notes: "boot")
        let instance = makeInstance(in: harness, name: "Measured") { $0.storageDisks = [installer, main] }
        let measured = VMBundleLayout.DiskSizes(onDiskBytes: 10_000_000_000, capacityBytes: 100_000_000_000)
        harness.snapshots.setDiskSizes(measured, for: main.id)

        let response = try await harness.transport.send(.storageDisks(.id(instance.id)))

        let mainPath = instance.bundleURL.appendingPathComponent("Disk.asif").path(percentEncoded: false)
        #expect(
            response.result
                == .storageDisks([
                    StorageDiskSummary(
                        id: installer.id, label: "Installer", kind: "usbMassStorage", readOnly: true,
                        path: installerPath, notes: "", capacityBytes: nil, usedBytes: nil),
                    StorageDiskSummary(
                        id: main.id, label: "Main Disk", kind: "virtio", readOnly: false, path: mainPath,
                        notes: "boot", capacityBytes: 100_000_000_000, usedBytes: 10_000_000_000),
                ]))
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
        let harness = makeHarness(usbAccessoryPassthrough: .available(accessories))
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
        let harness = makeHarness(usbAccessoryPassthrough: .available(accessories))
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

    // MARK: - Verbs

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

    @Test("Both guest-agent-disk edits cross the wire, a mount with the scopes it waits for")
    func guestAgentDiskEditsCrossTheWire() async throws {
        let installerPath = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, name: "Stub", phase: .running(sessionID: UUID()), guestOS: .macOS)
        instance.beginSessionContextForTesting().hasAgentTransport = true
        let selector = VMSelector.id(instance.id)

        // A mount naming no scopes waits for what an install of the guest OS's agent connects.
        #expect(try await harness.transport.send(.guestAgentDisk(selector, .mount(awaiting: nil))).result == .ok)
        #expect(instance.configuration.removableMedia?.map(\.path) == [installerPath])
        #expect(instance.guestAgentInstallerAwaits == [.login])
        // One naming scopes waits for exactly those.
        #expect(
            try await harness.transport.send(.guestAgentDisk(selector, .mount(awaiting: [.login, .system]))).result
                == .ok)
        #expect(instance.guestAgentInstallerAwaits == [.login, .system])
        #expect(try await harness.transport.send(.guestAgentDisk(selector, .mount(awaiting: []))).result == .ok)
        #expect(instance.guestAgentInstallerAwaits == [])

        #expect(try await harness.transport.send(.guestAgentDisk(selector, .unmount)).result == .ok)
        #expect(instance.configuration.removableMedia == nil)
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

    // MARK: - Envelope

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

    // MARK: - Ephemeral revert notices

    /// A stopped VM in Ephemeral Mode with `baseline` as its baseline.
    @discardableResult
    private func makeEphemeralInstance(
        in harness: Harness, name: String = "Alpha", baseline: VMSnapshot,
        phase: VMLifecyclePhase = .stopped, guestOS: VMGuestOS = .linux,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        harness.wired.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: [baseline],
            hostState: .ephemeral(baseline: baseline.id), mutate: mutate)
    }

    /// Each of `notices` as the VM it names and its baseline.
    private func named(_ notices: [VMCommandNotice]) -> [String] {
        notices.map { notice in
            switch notice {
            case .ephemeralRevert(let vm, let baseline): "\(vm.name) → \(baseline.name)"
            }
        }
    }

    @Test("A rename keeps the VM's name through a revert, so it carries no notice")
    func renameCarriesNoNotice() async throws {
        let harness = makeHarness()
        let instance = makeEphemeralInstance(in: harness, baseline: VMSnapshot(name: "Clean install", macAddress: nil))

        let response = try await harness.transport.send(.rename(.name("Alpha"), newName: "Beta"))

        #expect(response.result == .ok)
        #expect(instance.name == "Beta")
        #expect(response.notices.isEmpty)
    }

    @Test("A share removal on an Ephemeral VM carries the notice through the same answer")
    func shareRemovalCarriesTheNotice() async throws {
        let harness = makeHarness()
        makeEphemeralInstance(in: harness, baseline: VMSnapshot(name: "Clean install", macAddress: nil)) {
            $0.sharedDirectories = [SharedDirectory(path: "/Users/somebody/Sites")]
        }

        let response = try await harness.transport.send(
            .editSharedDirectory(.name("Alpha"), .removePath(path: "/Users/somebody/Sites")))

        #expect(response.result == .ok)
        #expect(named(response.notices) == ["Alpha → Clean install"])
    }
}
