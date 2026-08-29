import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// A stand-in for a wire transport: it encodes a request, hands the bytes to
/// the router, and decodes what comes back — the same round trip the CLI's pipe
/// will make, with no pipe.
@MainActor
private struct TestTransport {
    let router: VMCommandEnvelopeRouter

    func send(_ verb: VMCommandRequest.Verb) async throws -> VMCommandResponse {
        let request = try JSONEncoder().encode(VMCommandRequest(verb: verb))
        let response = try await router.handle(request)
        return try JSONDecoder().decode(VMCommandResponse.self, from: response)
    }

    func sendRaw(_ bytes: Data) async throws -> VMCommandResponse {
        try JSONDecoder().decode(VMCommandResponse.self, from: try await router.handle(bytes))
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
        let library: VMLibrary
        let storage: MockVMStorageService
        let virtualization: MockVirtualizationService
        let snapshots: MockVMSnapshotStore
    }

    private func makeHarness() -> Harness {
        let storage = MockVMStorageService()
        let virtualization = MockVirtualizationService()
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
            transport: TestTransport(router: VMCommandEnvelopeRouter(commands: core)),
            library: library, storage: storage, virtualization: virtualization,
            snapshots: snapshots)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Wired", status: VMStatus = .stopped
    ) -> VMInstance {
        var config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        config.networkEnabled = false
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, status: status, preferences: preferences)
        harness.library.instances.append(instance)
        harness.storage.bundles[bundleURL] = config
        return instance
    }

    // MARK: - Reads

    @Test("A listing crosses the wire as summaries")
    func listCrossesTheWire() async throws {
        let harness = makeHarness()
        makeInstance(in: harness, name: "First")
        makeInstance(in: harness, name: "Second", status: .running)

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

    // MARK: - Verbs

    @Test("A start crosses the wire and reaches the service")
    func startCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        let response = try await harness.transport.send(.start(.id(instance.id), recovery: false))

        #expect(response.result == .ok)
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("A snapshot capture answers with the snapshot that landed")
    func takeSnapshotCrossesTheWire() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, status: .running)

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
        let instance = makeInstance(in: harness, status: .running)

        let response = try await harness.transport.send(.start(.id(instance.id), recovery: false))

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
        #expect(harness.library.instances.count == 1)

        let confirmed = try await harness.transport.send(
            .delete(.id(instance.id), permanently: false, alsoRemoving: [], confirmed: true))

        #expect(confirmed.result == .ok)
        #expect(harness.library.instances.isEmpty)
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
        harness.storage.cloneVMBundleError = VMStorageError.bundleAlreadyExists(UUID())
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

        await #expect(throws: VMCommandEnvelopeRouter.EnvelopeError.self) {
            _ = try await harness.transport.sendRaw(Data("not a request".utf8))
        }
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A peer speaking another version of the vocabulary is refused")
    func foreignProtocolVersionIsRefused() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        var request = VMCommandRequest(verb: .start(.id(instance.id), recovery: false))
        request.protocolVersion = VMCommandRequest.currentProtocolVersion + 1

        let error = await #expect(throws: VMCommandEnvelopeRouter.EnvelopeError.self) {
            _ = try await harness.transport.sendRaw(try JSONEncoder().encode(request))
        }

        #expect(
            error
                == .unsupportedProtocolVersion(VMCommandRequest.currentProtocolVersion + 1))
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("The router drives anything that speaks the facade, not just the core")
    func routerDependsOnTheFacadeAlone() async throws {
        // Compiling at all is the assertion: the router takes `any VMCommanding`,
        // so a double with no library, no lifecycle coordinator and no VM behind
        // it answers the same envelope the core does.
        let double = StubCommands()
        let transport = TestTransport(router: VMCommandEnvelopeRouter(commands: double))

        let listed = try await transport.send(.list)
        #expect(listed.result == .summaries(StubCommands.listed))

        let refused = try await transport.send(.pause(.name("Anything")))
        #expect(refused.failure == .unsupported(capability: "pausing"))
    }
}

/// A ``VMCommanding`` that holds no VMs at all — enough to show the wire
/// boundary depends on the protocol and nothing under it.
@MainActor
private final class StubCommands: VMCommanding {
    static let listed = [
        VMSummary(
            id: UUID(uuid: (0xAA, 0xAA, 0xBB, 0xBB, 0xCC, 0xCC, 0xDD, 0xDD, 0xEE, 0xEE, 0, 0, 0, 0, 0, 0)),
            name: "Stub",
            status: "stopped")
    ]

    func list() -> [VMSummary] { Self.listed }
    func info(_ selector: VMSelector) throws -> VMInfo { throw CommandError.notFound(selector) }
    func ipAddress(of selector: VMSelector) throws -> String? { nil }
    func snapshots(of selector: VMSelector) throws -> [SnapshotSummary] { [] }

    func start(_ selector: VMSelector, recovery: Bool) async throws {}
    func stop(_ selector: VMSelector, disposition: StopDisposition, confirmed: Bool) async throws {}
    func pause(_ selector: VMSelector) async throws {
        throw CommandError.unsupported(capability: "pausing")
    }
    func resume(_ selector: VMSelector) async throws {}
    func suspend(_ selector: VMSelector) async throws {}
    func restart(_ selector: VMSelector) async throws {}
    func open(_ selector: VMSelector) throws {}

    func takeSnapshot(_ selector: VMSelector, name: String, notes: String) async throws
        -> SnapshotSummary
    {
        throw CommandError.notFound(selector)
    }
    func revertToSnapshot(
        _ selector: VMSelector, snapshot: UUID, takingCheckpoint: Bool, confirmed: Bool
    ) async throws {}
    func deleteSnapshot(_ selector: VMSelector, snapshot: UUID, confirmed: Bool) async throws {}
    func renameSnapshot(_ selector: VMSelector, snapshot: UUID, to newName: String) throws {}
    func setSnapshotNotes(_ selector: VMSelector, snapshot: UUID, notes: String) throws {}

    func clone(_ selector: VMSelector, machineIdentity: CloneMachineIdentity) throws -> VMSummary {
        throw CommandError.notFound(selector)
    }
    func rename(_ selector: VMSelector, to newName: String) throws {}
    func delete(
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, confirmed: Bool
    ) async throws {}
    func importVM(from url: URL) throws -> VMSummary {
        throw CommandError.notFound(.name(url.lastPathComponent))
    }
    func cancelPreparing(_ selector: VMSelector, confirmed: Bool) throws {}

    func events() -> AsyncStream<VMLibraryEvent> { AsyncStream { $0.finish() } }
}
