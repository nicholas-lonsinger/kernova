import Cocoa
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// A `Networks.json` Kernova can't read reads as unreadable on every surface
/// that lists the networks — never as none — and Use Defaults repairs it.
@Suite("Unreadable network list", .serialized, .caseScoped)
@MainActor
struct UnreadableNetworkListTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "UnreadableNetworkListTests")
    private let fileSystem = MockFileSystem()

    private var fileURL: URL { scratch.url.appendingPathComponent("Networks.json") }

    /// A network list whose one network's kind no kind spells.
    private var unreadableBytes: Data {
        Data(
            """
            {"networks": [{"id": "6A1F0B2C-3D4E-4F50-8A6B-7C8D9E0F1A2B", "name": "Lab", "kind": "plan9-mode"}]}
            """.utf8)
    }

    private struct Harness {
        let library: VMLibrary
        let core: VMCommandCore
    }

    private func makeHarness() throws -> Harness {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try unreadableBytes.write(to: fileURL)
        let storage = MockVMStorageService()
        let lifecycle = makeTestLifecycle(
            virtualization: MockVirtualizationService(), fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: MockVMBundleMachineFiles(files: storage.files),
            lifecycle: lifecycle, fileSystem: fileSystem, preferences: preferences,
            networks: VMNetworkDirectory(fileURL: fileURL))
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: preferences)
        return Harness(library: library, core: core)
    }

    private var refusal: CommandError {
        .operationFailed(verb: .networks, message: VMNetworkDirectory.unreadableMessage)
    }

    @Test("The directory holds the file as unreadable, with the path of what it found")
    func theDirectoryIsUnreadable() throws {
        let harness = try makeHarness()

        guard case .unreadable(let file) = harness.library.networks.state else {
            Issue.record("Expected an unreadable network list")
            return
        }
        #expect(file.location == .networkList(fileURL))
        #expect(file.owner == .networkList)
        #expect(file.problems.map(\.path?.description) == ["$.networks[0].kind"])
        #expect(file.isRepairable)
    }

    @Test("The command core refuses the listing, and every change, and leaves the file as it was")
    func theCoreRefuses() throws {
        let harness = try makeHarness()

        #expect(throws: refusal) { try harness.core.networks() }
        #expect(
            throws: CommandError.operationFailed(
                verb: .createNetwork, message: VMNetworkDirectory.unreadableMessage)
        ) { try harness.core.createNetwork(name: "Bench", kind: .hostOnly) }
        #expect(
            throws: CommandError.operationFailed(
                verb: .renameNetwork, message: VMNetworkDirectory.unreadableMessage)
        ) { try harness.core.renameNetwork("Lab", to: "Bench") }
        #expect(
            throws: CommandError.operationFailed(
                verb: .deleteNetwork, message: VMNetworkDirectory.unreadableMessage)
        ) { try harness.core.deleteNetwork("Lab") }
        #expect(try Data(contentsOf: fileURL) == unreadableBytes)
    }

    /// A VM in `harness`'s library naming the network `id`.
    @discardableResult
    private func registerMember(of id: UUID, in harness: Harness) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: "Member", phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences,
            mutate: {
                $0.applyNetworkMode(.shared)
                $0.networkMembership = .network(id)
            })
    }

    @Test("info reports a VM's named network as unreadable, never as its bare identifier")
    func infoReportsTheNameAsUnreadable() throws {
        let harness = try makeHarness()
        let member = registerMember(of: UUID(), in: harness)

        let info = try harness.core.info(.id(member.instanceID))

        #expect(info.networkName == .unreadable)
    }

    @Test("A membership write naming a network is refused with the unreadable list's message")
    func aNamedMembershipWriteIsRefused() throws {
        let harness = try makeHarness()
        let member = RegisteredVMInstanceFixture.register(
            name: "Member", phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences, mutate: { $0.applyNetworkMode(.shared) })

        for value in ["Lab", "6A1F0B2C-3D4E-4F50-8A6B-7C8D9E0F1A2B"] {
            #expect {
                try harness.core.setConfiguration(
                    .id(member.instanceID),
                    assignments: [ConfigurationEntry(key: "network.membership", value: value)],
                    consent: .none)
            } throws: { error in
                (error as? LocalizedError)?.errorDescription?.contains(VMNetworkDirectory.unreadableMessage)
                    == true
            }
        }
        #expect(member.configuration.networkMembership == .common)
        // A membership that names no network still writes.
        try harness.core.setConfiguration(
            .id(member.instanceID),
            assignments: [ConfigurationEntry(key: "network.membership", value: "isolated")],
            consent: .none)
        #expect(member.configuration.networkMembership == .isolated)
    }

    @Test("The wire answers the listing with the refusal")
    func theRouterRefuses() async throws {
        let harness = try makeHarness()
        let router = VMCommandEnvelopeRouter(commands: harness.core)

        let request = try JSONEncoder().encode(VMCommandRequest(verb: .networks))
        let response = try JSONDecoder().decode(
            VMCommandResponse.self, from: await router.handle(request))

        #expect(response.result == .failure(refusal.dto))
    }

    @Test("Shortcuts throws the refusal from every network query")
    func shortcutsRefuse() async throws {
        let harness = try makeHarness()
        let gateway = VMIntentGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())

        await #expect(throws: refusal) { try await gateway.networks() }
        await #expect(throws: refusal) { try await gateway.networks(matching: "Lab") }
        await #expect(throws: refusal) { try await gateway.networks(withIDs: [UUID()]) }
    }

    @Test("AppleScript records the refusal on the command it answers")
    func appleScriptRefuses() throws {
        let harness = try makeHarness()
        let gateway = VMScriptingGateway(
            commands: harness.core, readiness: LibraryReadiness(awaitReady: {}),
            prepareToSurface: {})
        let command = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "core"),
                andAppleEventCode: FourCharCode(scriptingCode: "getd")
            )?.createCommandInstance())
        gateway.answeringCommand = command

        #expect(gateway.networks().isEmpty)
        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
    }

    @Test("Use Defaults puts the default kind in place, trashes the original, and lists the network")
    func useDefaultsRepairsTheList() async throws {
        let harness = try makeHarness()
        let files = try await harness.library.checkConfigFiles()
        #expect(files.map(\.location) == [.networkList(fileURL)])

        let failures = await harness.library.useDefaults(in: files)

        #expect(failures.isEmpty)
        #expect(fileSystem.trashedURLs.map(\.lastPathComponent) == ["Network list \u{2014} Networks.json"])
        let listed = try harness.core.networks()
        #expect(listed.map(\.name) == ["Lab"])
        #expect(listed.map(\.kind) == [NetworkKind(VMNamedNetwork.defaultKind)])
        #expect(try await harness.library.checkConfigFiles().isEmpty)
    }
}
