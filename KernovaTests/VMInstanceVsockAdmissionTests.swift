import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Synchronization
import Testing

@testable import Kernova

/// The #145 feature-channel admission wiring: the control service publishes its
/// handshake into the instance's `VsockAdmissionGate`, and replacing or tearing
/// the service down withdraws admission. The verdict semantics themselves are
/// `VsockAdmissionGateTests`'.
@Suite("VMInstance vsock feature-channel admission")
@MainActor
struct VMInstanceVsockAdmissionTests {
    // MARK: - Helpers

    private final class RecordingAcceptor: VsockDataConnectionAccepting {
        nonisolated func acceptDataConnection(fd: Int32) {
            // Keep the descriptor open: a forwarded fd is the probe's signal.
        }
    }

    private func makeInstance() -> VMInstance {
        let config = VMConfiguration(name: "Admission VM", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    /// Builds the control service as `startVsockServices()`'s accept path does,
    /// wired to the instance's gate.
    private func makeControlService(
        for instance: VMInstance, channel: VsockChannel
    ) -> VsockControlService {
        let control = instance.makeControlService(for: channel)
        instance.vsockControlService = control
        control.start()
        return control
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
        instance.vsockAdmissionGate.admission(for: clipboard ? .clipboardStreaming : .none)
            == .admit
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
                instance.vsockAdmissionGate.admission(
                    for: clipboard ? .clipboardStreaming : .none)))
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

        let control = makeControlService(for: instance, channel: host)
        defer { control.stop() }

        // Channel accepted but no guest Hello yet — still refused, and as the
        // routine "too early" verdict rather than a peer that overstepped.
        #expect(isNotReady(instance.vsockAdmissionGate.admission(for: .none)))

        // A Hello without the streaming capability admits the log channel; the
        // clipboard channel is refused against a *completed* handshake, so that
        // refusal names the peer.
        try guest.send(makeGuestHello(streamingCapable: false))
        try await waitForChange { control.isConnected }
        #expect(admits(instance, clipboard: false))
        #expect(isDenied(instance.vsockAdmissionGate.admission(for: .clipboardStreaming)))

        // A Hello advertising streaming flips clipboard admission too.
        try guest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange { control.guestSupportsClipboardStreaming }
        #expect(admits(instance, clipboard: true))
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

        let control = makeControlService(for: instance, channel: host)

        try guest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange { control.guestSupportsClipboardStreaming }
        #expect(admits(instance, clipboard: true))

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

        let first = makeControlService(for: instance, channel: firstHost)

        try firstGuest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange { first.guestSupportsClipboardStreaming }
        #expect(admits(instance, clipboard: true))

        // Nobody calls stop() when a guest agent simply disappears — the
        // service settles itself, and admission drops with it rather than
        // keeping log and clipboard channels admitted onto a dead channel.
        firstGuest.close()
        try await waitForChange { !first.isConnected }
        #expect(!admits(instance, clipboard: false))
        #expect(!admits(instance, clipboard: true))

        // The accept path, as `startVsockServices()` runs it: stop whatever is
        // installed (a no-op on an already-settled service) and install a fresh
        // one for the new channel. Admission stays withdrawn until its Hello.
        let (secondGuestFd, secondHostFd) = try makeRawSocketPair()
        let secondGuest = VsockChannel(fileDescriptor: secondGuestFd)
        let secondHost = VsockChannel(fileDescriptor: secondHostFd)
        secondGuest.start()
        secondHost.start()
        defer { secondGuest.close() }

        instance.vsockControlService?.stop()
        #expect(!admits(instance, clipboard: false))
        let second = makeControlService(for: instance, channel: secondHost)
        defer { second.stop() }

        try secondGuest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange { second.guestSupportsClipboardStreaming }
        #expect(admits(instance, clipboard: true))
        #expect(instance.vsockControlService !== first)
    }

    // MARK: - Drop channel

    @Test("The drop channel is refused before the handshake, and without drop.files.v3")
    func dropAdmissionFollowsItsOwnCapability() async throws {
        let instance = makeInstance()
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()
        defer { guest.close() }

        #expect(isNotReady(instance.vsockAdmissionGate.admission(for: .dropFiles)))

        let control = makeControlService(for: instance, channel: host)
        defer { control.stop() }

        // An agent that streams the clipboard but predates display drops gets
        // the log and clipboard channels and not this one.
        try guest.send(
            makeGuestHello(capabilities: [
                KernovaCapability.controlV1, KernovaCapability.controlHeartbeatV1,
                KernovaCapability.clipboardTransferV3,
            ]))
        try await waitForChange { control.guestSupportsClipboardStreaming }
        #expect(admits(instance, clipboard: true))
        #expect(isDenied(instance.vsockAdmissionGate.admission(for: .dropFiles)))

        try guest.send(makeGuestHello(capabilities: KernovaCapability.controlChannelDefaults))
        try await waitForChange { control.guestSupportsDropFiles }
        #expect(instance.vsockAdmissionGate.admission(for: .dropFiles) == .admit)
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

        let control = makeControlService(for: instance, channel: host)

        try guest.send(makeGuestHello(streamingCapable: true))
        try await waitForChange { control.guestSupportsDropFiles }
        #expect(instance.vsockAdmissionGate.admission(for: .dropFiles) == .admit)

        control.stop()
        #expect(instance.vsockAdmissionGate.admission(for: .dropFiles) != .admit)
    }

    // MARK: - Data ports

    /// Each transfer dials a port of its own, so a collision would silently hand
    /// one service's connections to another's listener.
    @Test("Every vsock port is distinct")
    func portsAreDistinct() {
        let ports = [
            KernovaVsockPort.control, KernovaVsockPort.clipboard, KernovaVsockPort.log,
            KernovaVsockPort.drop, KernovaVsockPort.clipboardData, KernovaVsockPort.dropData,
        ]
        #expect(Set(ports).count == ports.count)
    }

    @Test("Tearing the vsock services down clears the gate and the data sinks")
    func stopClearsGateAndSinks() throws {
        let instance = makeInstance()
        instance.vsockAdmissionGate.publish(
            VsockAdmissionGate.State(
                handshakeComplete: true,
                capabilities: Set(KernovaCapability.controlChannelDefaults)))
        // A probe that would keep a forwarded descriptor open, so EOF below
        // proves the sink was cleared rather than never set.
        instance.clipboardDataSink.set(RecordingAcceptor())
        instance.dropDataSink.set(RecordingAcceptor())

        instance.stopVsockServices()

        #expect(isNotReady(instance.vsockAdmissionGate.admission(for: .none)))
        for sink in [instance.clipboardDataSink, instance.dropDataSink] {
            let (a, b) = try makeRawSocketPair()
            defer { close(b) }  // `a` is owned — and must be closed — by the sink.
            sink.accept(fd: a)
            #expect(fcntl(b, F_SETFL, O_NONBLOCK) >= 0)
            var byte: UInt8 = 0
            #expect(recv(b, &byte, 1, 0) == 0)
        }
    }

    // MARK: - Stale-session hand-offs

    /// One of the four framed listeners a session installs: how it is built,
    /// and what an accepted channel populates on the instance.
    private struct FramedListener {
        let port: String
        let makeHost: @MainActor (VMInstance, UUID) -> VsockListenerHost
        let isInstalled: @MainActor (VMInstance) -> Bool
    }

    private var framedListeners: [FramedListener] {
        [
            FramedListener(
                port: "control",
                makeHost: { $0.makeControlListenerHost(sessionID: $1) },
                isInstalled: { $0.vsockControlService != nil }),
            FramedListener(
                port: "log",
                makeHost: { $0.makeLogListenerHost(sessionID: $1) },
                isInstalled: { $0.vsockLogService != nil }),
            FramedListener(
                port: "drop",
                makeHost: { $0.makeDropListenerHost(sessionID: $1) },
                isInstalled: { $0.vsockDropService != nil }),
            FramedListener(
                port: "clipboard",
                makeHost: { $0.makeClipboardListenerHost(sessionID: $1) },
                isInstalled: { $0.clipboardService != nil }),
        ]
    }

    /// An instance standing in for one with a live session, its handshake
    /// published so the feature ports admit a connection.
    private func makeInstanceWithLiveSession() -> (instance: VMInstance, sessionID: UUID) {
        let instance = makeInstance()
        let sessionID = UUID()
        instance.liveSessionIDOverrideForTesting = sessionID
        instance.vsockAdmissionGate.publish(
            VsockAdmissionGate.State(
                handshakeComplete: true,
                capabilities: Set(KernovaCapability.controlChannelDefaults)))
        return (instance, sessionID)
    }

    @Test("Each framed listener installs its service for the session that built it")
    func liveSessionHandOffInstallsTheService() async throws {
        for listener in framedListeners {
            let (instance, sessionID) = makeInstanceWithLiveSession()
            let host = listener.makeHost(instance, sessionID)
            let (acceptedFd, guestFd) = try makeRawSocketPair()
            let guest = VsockChannel(fileDescriptor: guestFd)
            guest.start()
            defer { guest.close() }

            #expect(host.acceptDuplicatedFd(acceptedFd, dupErrno: 0))
            await drainMainQueue()

            #expect(listener.isInstalled(instance), "\(listener.port): no service installed")
            instance.tearDownSession()
        }
    }

    /// The accept runs on the VM's queue and queues the hand-off; a stop
    /// running on main in between clears every service, and the hand-off that
    /// lands after it must not put them back — `VMInstance` outlives the
    /// session, so nothing else would ever clear them.
    @Test("A hand-off queued by a released session installs nothing and closes its channel")
    func releasedSessionHandOffIsRefused() async throws {
        for listener in framedListeners {
            let (instance, sessionID) = makeInstanceWithLiveSession()
            let host = listener.makeHost(instance, sessionID)
            let (acceptedFd, guestFd) = try makeRawSocketPair()
            let guest = VsockChannel(fileDescriptor: guestFd)
            guest.start()
            defer { guest.close() }

            // Admitted while the session is live, so the refusal under test is
            // the hand-off's own and not the admission gate's.
            #expect(host.acceptDuplicatedFd(acceptedFd, dupErrno: 0))
            // The user stops the VM before the queued hand-off gets its turn on
            // main. Releasing the stand-in identity is what `tearDownSession`
            // does to `session` itself.
            instance.tearDownSession()
            instance.liveSessionIDOverrideForTesting = nil

            await drainMainQueue()

            #expect(
                !listener.isInstalled(instance),
                "\(listener.port): a stopped instance was repopulated")
            await expectEOF(on: guest)
        }
    }

    @Test("Tearing the session down clears the gate")
    func tearDownSessionClearsGate() {
        let instance = makeInstance()
        instance.vsockAdmissionGate.publish(
            VsockAdmissionGate.State(handshakeComplete: true))

        instance.tearDownSession()

        #expect(isNotReady(instance.vsockAdmissionGate.admission(for: .none)))
    }
}
