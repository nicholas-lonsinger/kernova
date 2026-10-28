import Foundation
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization
@testable import KernovaVirtualizationTestSupport

@Suite("Validated configuration Tests", .caseScoped)
struct ValidatedConfigurationTests {
    private let scratch = TestScratchDirectory(prefix: "ValidatedConfigurationTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - Clipboard Sharing

    @Test(
        "BuildResult includes clipboard pipes when clipboard sharing is enabled",
        .enabled(if: VZVirtualMachine.isSupported)
    )
    func clipboardPipesWhenEnabled() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        var config = VMConfiguration.testLinux()
        config.clipboardSharingEnabled = true

        let result = try await ConfigurationBuilder.testing().build(from: config, bundleURL: bundleURL)

        #expect(result.products.clipboardInputPipe != nil)
        #expect(result.products.clipboardOutputPipe != nil)
    }

    @Test(
        "BuildResult has nil clipboard pipes when clipboard sharing is disabled",
        .enabled(if: VZVirtualMachine.isSupported)
    )
    func clipboardPipesWhenDisabled() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        var config = VMConfiguration.testLinux()
        config.clipboardSharingEnabled = false

        let result = try await ConfigurationBuilder.testing().build(from: config, bundleURL: bundleURL)

        #expect(result.products.clipboardInputPipe == nil)
        #expect(result.products.clipboardOutputPipe == nil)
    }

    // MARK: - Session

    @Test(
        "A session over a validated configuration snapshots the devices its VM was built with",
        .enabled(if: VZVirtualMachine.isSupported),
        arguments: [true, false]
    )
    func sessionSnapshotsItsDevices(networkEnabled: Bool) async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        var config = VMConfiguration.testLinux()
        config.networkEnabled = networkEnabled
        let result = try await ConfigurationBuilder.testing().build(from: config, bundleURL: bundleURL)

        let session = await VMSession.make(
            configuration: result.configuration, events: VMSessionEvents(handle: { _, _ in }))

        #expect(session.hasNetworkDevice == networkEnabled)
        #expect(session.hasUSBController)
        #expect(session.hasVirtioSocketDevice)
    }

    @Test(
        "A Linux session's vsock services attach the agent hub a transport",
        .enabled(if: VZVirtualMachine.isSupported)
    )
    @MainActor
    func linuxSessionAttachesTheAgentHub() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let result = try await ConfigurationBuilder.testing().build(
            from: VMConfiguration.testLinux(), bundleURL: bundleURL)
        let session = await VMSession.make(
            configuration: result.configuration, events: VMSessionEvents(handle: { _, _ in }))
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: session.id))
        let context = instance.beginSessionContextForTesting()
        context.session = session

        await instance.startVsockServices()

        #expect(context.hasAgentTransport)
        #expect(instance.agentPresentation?.hub != nil)
        context.tearDown()
    }
}
