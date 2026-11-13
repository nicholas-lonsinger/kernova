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
        "A Linux session attaches the agent hub a transport",
        .enabled(if: VZVirtualMachine.isSupported)
    )
    @MainActor
    func linuxSessionAttachesTheAgentHub() async throws {
        let (instance, context) = try await attachAgentTransport(deviceShape: .current)

        #expect(context.hasAgentTransport)
        instance.handleSessionEvent(.guestDidStop)
    }

    @Test(
        "A Linux session restored from a config with no device record has no socket device or hub transport",
        .enabled(if: VZVirtualMachine.isSupported)
    )
    @MainActor
    func unrecordedLinuxShapeAttachesNoHub() async throws {
        let encoded = try VMConfiguration.makeJSONEncoder().encode(VMConfiguration.testLinux())
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["deviceShape"] = nil
        let unrecorded = try VMConfiguration.makeJSONDecoder().decode(
            VMConfiguration.self, from: JSONSerialization.data(withJSONObject: object))

        let (instance, context) = try await attachAgentTransport(deviceShape: unrecorded.deviceShape)

        #expect(context.session?.hasVirtioSocketDevice == false)
        #expect(!context.hasAgentTransport)
        instance.handleSessionEvent(.guestDidStop)
    }

    /// Attaches a Linux instance's agent transport over a real session built
    /// from a configuration recording `deviceShape`, answering the session's
    /// context.
    @MainActor
    private func attachAgentTransport(
        deviceShape: VMDeviceShape
    ) async throws -> (VMInstance, VMSessionContext) {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        var config = VMConfiguration.testLinux()
        config.deviceShape = deviceShape
        let result = try await ConfigurationBuilder.testing().build(from: config, bundleURL: bundleURL)
        let session = await VMSession.make(
            configuration: result.configuration, events: VMSessionEvents(handle: { _, _ in }))
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: session.id))
        let context = instance.beginSessionContextForTesting()
        context.session = session

        instance.attachSessionAgentTransport()
        #expect((instance.agentPresentation != nil) == context.hasAgentTransport)
        return (instance, context)
    }
}
