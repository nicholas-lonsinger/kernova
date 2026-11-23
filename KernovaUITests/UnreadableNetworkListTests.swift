import Cocoa
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

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

    private func makeHarness() throws -> WiredCommandCore {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try unreadableBytes.write(to: fileURL)
        return WiredCommandCore(
            fileSystem: fileSystem, networks: VMNetworkDirectory(fileURL: fileURL),
            preferences: preferences)
    }

    private var refusal: CommandError {
        .operationFailed(verb: .networks, message: VMNetworkDirectory.unreadableMessage)
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

    @Test("The wire answers the listing with the refusal")
    func theRouterRefuses() async throws {
        let harness = try makeHarness()
        let router = VMCommandEnvelopeRouter(commands: harness.core)

        let request = try JSONEncoder().encode(VMCommandRequest(verb: .networks))
        let decoded = try #require(try? router.decode(request).get())
        let response = try JSONDecoder().decode(
            VMCommandResponse.self, from: router.encode(await router.respond(to: decoded)))

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
    func appleScriptRefuses() async throws {
        let harness = try makeHarness()
        let standIn = ScriptCommandStandIn()
        let readiness = LibraryReadiness(awaitReady: {})
        await readiness.ready()
        let gateway = VMScriptingGateway(
            commands: harness.core, readiness: readiness, prepareToSurface: {}, runtime: standIn.runtime)
        let command = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "core"),
                andAppleEventCode: FourCharCode(scriptingCode: "getd")
            )?.createCommandInstance())
        standIn.command = command

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
