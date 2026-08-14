import Foundation
import KernovaKit
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
        makeGuestHello(
            capabilities: streamingCapable
                ? KernovaCapability.controlChannelDefaults
                : [KernovaCapability.controlV1, KernovaCapability.controlHeartbeatV1])
    }

    private func makeGuestHello(capabilities: [String]) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = capabilities
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = "1.0.0"
            }
        }
        return frame
    }

    /// The verdict as the listener acts on it, for the assertions that only care
    /// whether the channel gets in.
    private func admits(_ instance: VMInstance, clipboard: Bool) -> Bool {
        instance.featureChannelAdmission(clipboard ? .clipboardStreaming : .none) == .admit
    }

    /// Whether the refusal is the routine "handshake hasn't landed" one, which
    /// the listener logs below `.warning`.
    ///
    /// The reason text is not a contract.
    private func isNotReady(_ verdict: VsockAdmission) -> Bool {
        if case .notReady = verdict { return true }
        return false
    }

    /// Whether the refusal is the one that names the peer.
    private func isDenied(_ verdict: VsockAdmission) -> Bool {
        if case .denied = verdict { return true }
        return false
    }

    // MARK: - Tests

    @Test("Nothing is admitted without a control service", arguments: [false, true])
    func refusedWithoutControlService(clipboard: Bool) {
        let instance = makeInstance()
        #expect(
            isNotReady(
                instance.featureChannelAdmission(clipboard ? .clipboardStreaming : .none)))
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

        // Channel accepted but no guest Hello yet — still refused, and as the
        // routine "too early" verdict rather than a peer that overstepped.
        #expect(isNotReady(instance.featureChannelAdmission(.none)))

        // A Hello without the streaming capability admits the log channel; the
        // clipboard channel is refused against a *completed* handshake, so that
        // refusal names the peer.
        try guest.send(makeGuestHello(streamingCapable: false))
        try await waitForChange { admits(instance, clipboard: false) }
        #expect(isDenied(instance.featureChannelAdmission(.clipboardStreaming)))

        // A Hello advertising streaming flips clipboard admission too.
        try guest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange { admits(instance, clipboard: true) }
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
        try await waitForChange { admits(instance, clipboard: true) }

        // stop() resets the handshake state — admission drops with it, so a
        // feature connection racing a control teardown is refused.
        control.stop()
        #expect(!admits(instance, clipboard: false))
        #expect(!admits(instance, clipboard: true))
    }

    @Test("A dead control channel withdraws admission, and a reconnect restores it")
    func settleThenReconnectRestoresAdmission() async throws {
        let instance = makeInstance()
        let (firstGuestFd, firstHostFd) = try makeRawSocketPair()
        let firstGuest = VsockChannel(fileDescriptor: firstGuestFd)
        let firstHost = VsockChannel(fileDescriptor: firstHostFd)
        firstGuest.start()
        firstHost.start()
        defer { firstGuest.close() }

        let first = VsockControlService(channel: firstHost, label: "admission-test")
        instance.vsockControlService = first
        first.start()

        try firstGuest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange { admits(instance, clipboard: true) }

        // Nobody calls stop() when a guest agent simply disappears — the
        // service settles itself, and admission drops with it rather than
        // keeping log and clipboard channels admitted onto a dead channel.
        firstGuest.close()
        try await waitForChange { !admits(instance, clipboard: false) }
        #expect(!admits(instance, clipboard: true))

        // The accept path, as `startVsockServices()` runs it: stop whatever is
        // installed (a no-op on an already-settled service) and install a fresh
        // one for the new channel.
        let (secondGuestFd, secondHostFd) = try makeRawSocketPair()
        let secondGuest = VsockChannel(fileDescriptor: secondGuestFd)
        let secondHost = VsockChannel(fileDescriptor: secondHostFd)
        secondGuest.start()
        secondHost.start()
        defer { secondGuest.close() }

        instance.vsockControlService?.stop()
        let second = VsockControlService(channel: secondHost, label: "admission-test")
        instance.vsockControlService = second
        second.start()
        defer { second.stop() }

        try secondGuest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange { admits(instance, clipboard: true) }
        #expect(instance.vsockControlService !== first)
    }

    // MARK: - Drop channel

    @Test("The drop channel is refused before the handshake, and without drop.files.v1")
    func dropAdmissionFollowsItsOwnCapability() async throws {
        let instance = makeInstance()
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()
        defer { guest.close() }

        #expect(isNotReady(instance.featureChannelAdmission(.dropFiles)))

        let control = VsockControlService(channel: host, label: "admission-test")
        instance.vsockControlService = control
        control.start()
        defer { control.stop() }

        // An agent that streams the clipboard but predates display drops gets
        // the log and clipboard channels and not this one.
        try guest.send(
            makeGuestHello(capabilities: [
                KernovaCapability.controlV1, KernovaCapability.controlHeartbeatV1,
                KernovaCapability.clipboardStreamV1,
            ]))
        try await waitForChange { admits(instance, clipboard: true) }
        #expect(isDenied(instance.featureChannelAdmission(.dropFiles)))

        try guest.send(makeGuestHello(capabilities: KernovaCapability.controlChannelDefaults))
        try await waitForChange { instance.featureChannelAdmission(.dropFiles) == .admit }
    }

    @Test("Stopping the control service withdraws drop admission too")
    func stopWithdrawsDropAdmission() async throws {
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
        try await waitForChange { instance.featureChannelAdmission(.dropFiles) == .admit }

        control.stop()
        #expect(instance.featureChannelAdmission(.dropFiles) != .admit)
    }
}
