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
