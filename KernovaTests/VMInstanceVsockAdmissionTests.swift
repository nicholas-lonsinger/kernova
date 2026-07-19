import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The #145 feature-channel admission predicate: log/clipboard vsock listeners
/// only admit connections while a control channel with a completed `Hello`
/// handshake exists — clipboard additionally requires the negotiated
/// `clipboard.stream.v1` capability.
@Suite("VMInstance vsock feature-channel admission")
@MainActor
struct VMInstanceVsockAdmissionTests {
    // MARK: - Helpers

    private func makeInstance() -> VMInstance {
        let config = VMConfiguration(name: "Admission VM", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    private func makeGuestHello(streamingCapable: Bool) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities =
                streamingCapable
                ? KernovaCapability.controlChannelDefaults
                : [KernovaCapability.controlV1, KernovaCapability.controlHeartbeatV1]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = "1.0.0"
            }
        }
        return frame
    }

    // MARK: - Tests

    @Test("Nothing is admitted without a control service")
    func refusedWithoutControlService() {
        let instance = makeInstance()
        #expect(!instance.admitsFeatureChannel(requiringClipboardStreaming: false))
        #expect(!instance.admitsFeatureChannel(requiringClipboardStreaming: true))
    }

    @Test("Admission follows the control Hello handshake and its capabilities")
    func admissionFollowsControlHandshake() async throws {
        let instance = makeInstance()
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()
        defer { guest.close() }

        let control = VsockControlService(channel: host, label: "admission-test")
        instance.vsockControlService = control
        control.start()
        defer { control.stop() }

        // Channel accepted but no guest Hello yet — still refused.
        #expect(!instance.admitsFeatureChannel(requiringClipboardStreaming: false))

        // A Hello without the streaming capability admits the log channel but
        // not the clipboard channel.
        try guest.send(makeGuestHello(streamingCapable: false))
        try await waitForChange {
            instance.admitsFeatureChannel(requiringClipboardStreaming: false)
        }
        #expect(!instance.admitsFeatureChannel(requiringClipboardStreaming: true))

        // A Hello advertising streaming flips clipboard admission too.
        try guest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange {
            instance.admitsFeatureChannel(requiringClipboardStreaming: true)
        }
    }

    @Test("Stopping the control service withdraws admission")
    func stopWithdrawsAdmission() async throws {
        let instance = makeInstance()
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()
        defer { guest.close() }

        let control = VsockControlService(channel: host, label: "admission-test")
        instance.vsockControlService = control
        control.start()

        try guest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange {
            instance.admitsFeatureChannel(requiringClipboardStreaming: true)
        }

        // stop() resets the handshake state — admission drops with it, so a
        // feature connection racing a control teardown is refused.
        control.stop()
        #expect(!instance.admitsFeatureChannel(requiringClipboardStreaming: false))
        #expect(!instance.admitsFeatureChannel(requiringClipboardStreaming: true))
    }
}
