import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A stand-in for a wire transport: it encodes a request, has the router
/// decode, answer and encode it as `VMCommandSocketListener` does, and decodes
/// what comes back — the same round trip a transport makes, with no transport.
@MainActor
private struct TestTransport {
    let router: VMCommandEnvelopeRouter

    func send(_ verb: VMCommandRequest.Verb) async throws -> VMCommandResponse {
        try await sendRaw(JSONEncoder().encode(VMCommandRequest(verb: verb)))
    }

    func sendRaw(_ bytes: Data) async throws -> VMCommandResponse {
        let answer: VMCommandResponse
        switch router.decode(bytes) {
        case .failure(let refusal):
            answer = VMCommandResponse(result: .refused(refusal))
        case .success(let request):
            answer = await router.respond(to: request)
        }
        return try JSONDecoder().decode(VMCommandResponse.self, from: router.encode(answer))
    }
}

extension VMCommandResponse {
    /// The refusal this response carries, or `nil` when the verb succeeded —
    /// what a client reads matching `.failure` on ``result``, as the CLI does.
    fileprivate var failure: CommandErrorDTO? {
        guard case .failure(let error) = result else { return nil }
        return error
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

        var library: VMLibrary { wired.library }
        var storage: MockVMStorageService { wired.storage }
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

    // MARK: - Configuration

    @Test("The keyspace, a read and a write each cross the wire as their own payload")
    func configurationVerbsCrossTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, name: "Alpha", guestOS: .macOS) {
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
}
