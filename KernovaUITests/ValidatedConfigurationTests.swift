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

    @Test("BuildResult includes clipboard pipes when clipboard sharing is enabled")
    func clipboardPipesWhenEnabled() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var config = VMConfiguration.testLinux()
        config.clipboardSharingEnabled = true

        let builder = ConfigurationBuilder.testing()
        do {
            let result = try builder.build(from: config, bundleURL: bundleURL)
            #expect(result.products.clipboardInputPipe != nil)
            #expect(result.products.clipboardOutputPipe != nil)
        } catch {
            let isVZError = (error as NSError).domain == "VZErrorDomain"
            if isVZError {
                withKnownIssue("VZ validation unavailable — assertions skipped") {
                    Issue.record("\(error)")
                }
            } else {
                Issue.record("Unexpected non-VZ error: \(error)")
            }
        }
    }

    @Test("BuildResult has nil clipboard pipes when clipboard sharing is disabled")
    func clipboardPipesWhenDisabled() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var config = VMConfiguration.testLinux()
        config.clipboardSharingEnabled = false

        let builder = ConfigurationBuilder.testing()
        do {
            let result = try builder.build(from: config, bundleURL: bundleURL)
            #expect(result.products.clipboardInputPipe == nil)
            #expect(result.products.clipboardOutputPipe == nil)
        } catch {
            let isVZError = (error as NSError).domain == "VZErrorDomain"
            if isVZError {
                withKnownIssue("VZ validation unavailable — assertions skipped") {
                    Issue.record("\(error)")
                }
            } else {
                Issue.record("Unexpected non-VZ error: \(error)")
            }
        }
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
        let result = try ConfigurationBuilder.testing().build(from: config, bundleURL: bundleURL)

        let session = await VMSession.make(
            configuration: result.configuration, events: VMSessionEvents(handle: { _, _ in }))

        #expect(session.hasNetworkDevice == networkEnabled)
        #expect(session.hasUSBController)
        #expect(session.hasVirtioSocketDevice == !result.configuration.socketDevices.isEmpty)
    }
}
