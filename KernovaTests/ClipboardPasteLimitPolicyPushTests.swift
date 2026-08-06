import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The app-wide paste ceiling reaching a running guest, over a real control
/// channel.
///
/// The ceiling lives in `AppPreferences`, so it produces no `VMConfiguration`
/// diff for `applyLivePolicy` to carry — without an explicit re-push a running
/// guest keeps enforcing the value it was handed at connect, and the two ends
/// silently disagree until the next reconnect.
@Suite("Clipboard paste ceiling policy push", .serialized)
@MainActor
struct ClipboardPasteLimitPolicyPushTests {
    private func makeInstance(preferences: AppPreferences) -> VMInstance {
        var config = VMConfiguration(name: "Ceiling VM", guestOS: .macOS, bootMode: .macOS)
        config.clipboardSharingEnabled = true
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, status: .running,
            preferences: preferences)
        instance.hasLiveVirtualMachineOverrideForTesting = true
        return instance
    }

    private func makeGuestHello(pasteLimitCapable: Bool = true) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities =
                pasteLimitCapable
                ? KernovaCapability.controlChannelDefaults
                : [
                    KernovaCapability.controlV1, KernovaCapability.controlHeartbeatV1,
                    KernovaCapability.clipboardStreamV1,
                ]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = "0.54.0"
            }
        }
        return frame
    }

    /// Installs a production-wired control service on `instance`, mirroring the
    /// accept closure in `startVsockServices()`, and returns the guest end.
    private func attachControlService(to instance: VMInstance) throws -> VsockChannel {
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()

        instance.vsockControlService?.stop()
        let service = instance.makeControlService(for: host)
        instance.vsockControlService = service
        service.start()
        return guest
    }

    /// Reads frames from `guest` until a `PolicyUpdate` arrives.
    private func nextPolicy(from guest: VsockChannel) async throws -> Kernova_V1_PolicyUpdate {
        for _ in 0..<6 {
            let next = try await nextFrame(from: guest)
            if case .policyUpdate(let policy) = next.payload { return policy }
        }
        Issue.record("No PolicyUpdate arrived")
        throw CancellationError()
    }

    @Test("changing the ceiling re-pushes policy to a connected guest, without a reconnect")
    func changingTheCeilingRePushes() async throws {
        let preferences = makeEphemeralPreferences(suiteName: "test.kernova.ceiling-push")
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences)

        let instance = makeInstance(preferences: preferences)
        viewModel.instances.append(instance)
        let guest = try attachControlService(to: instance)
        defer {
            instance.stopVsockServices()
            guest.close()
        }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello())

        // The connect-time push carries whatever is stored now.
        let initial = try await nextPolicy(from: guest)
        #expect(initial.clipboardMaxPasteBytes == UInt64(preferences.clipboardMaxPasteBytes))

        // The Settings pane's action, verbatim: write the preference, then ask
        // the library to carry it to every running guest.
        let raised = 16 * 1024 * 1024 * 1024
        preferences.clipboardMaxPasteBytes = raised
        viewModel.applyClipboardPasteLimitChange()

        let pushed = try await nextPolicy(from: guest)
        #expect(pushed.clipboardMaxPasteBytes == UInt64(raised))
        // The host's own checks agree with what the guest was just told.
        #expect(instance.effectiveClipboardMaxPasteBytes == raised)
    }

    @Test("the re-push holds an agent without the capability at the default, host included")
    func rePushHeldAtDefaultWithoutCapability() async throws {
        let preferences = makeEphemeralPreferences(suiteName: "test.kernova.ceiling-push-old")
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences)

        let instance = makeInstance(preferences: preferences)
        viewModel.instances.append(instance)
        let guest = try attachControlService(to: instance)
        defer {
            instance.stopVsockServices()
            guest.close()
        }

        _ = try await nextFrame(from: guest)  // host hello
        try guest.send(makeGuestHello(pasteLimitCapable: false))
        _ = try await nextPolicy(from: guest)  // connect-time push

        let raised = 16 * 1024 * 1024 * 1024
        preferences.clipboardMaxPasteBytes = raised
        viewModel.applyClipboardPasteLimitChange()

        let pushed = try await nextPolicy(from: guest)
        // The older agent enforces its own built-in ceiling whatever it is sent,
        // so the host must not admit a paste it will refuse.
        #expect(pushed.clipboardMaxPasteBytes == UInt64(ClipboardPasteLimit.defaultBytes))
        #expect(instance.effectiveClipboardMaxPasteBytes == ClipboardPasteLimit.defaultBytes)
    }
}
