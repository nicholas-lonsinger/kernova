import Darwin
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the live clipboard and log toggles move on the VM's socket device, and
/// what they leave behind on the instance. The session owns the listener hosts,
/// so a port coming down and its host being released are one queue hop; these
/// pin the ports each toggle moves and that the clipboard pair moves together.
@Suite("VMInstance live vsock policy")
@MainActor
struct VMInstanceLiveVsockPolicyTests {
    // MARK: - Helpers

    private final class RecordingAcceptor: VsockDataConnectionAccepting {
        nonisolated func acceptDataConnection(fd: Int32) {
            // Keep the descriptor open: a forwarded fd is the probe's signal.
        }
    }

    /// An instance standing in for one with a live session, its handshake
    /// published so the feature ports admit a connection.
    private func makeInstanceWithLiveSession() -> (instance: VMInstance, sessionID: UUID) {
        let config = VMConfiguration(name: "Live Policy VM", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        let sessionID = UUID()
        instance.liveSessionIDOverrideForTesting = sessionID
        instance.vsockAdmissionGate.publish(
            VsockAdmissionGate.State(
                handshakeComplete: true,
                capabilities: Set(KernovaCapability.controlChannelDefaults)))
        return (instance, sessionID)
    }

    /// Runs `host`'s accept path against a live peer, the way a guest dial
    /// installs the service behind a framed port.
    private func connectGuest(
        to host: VsockListenerHost, keptOpenBy retained: inout [VsockChannel]
    ) async throws {
        let (acceptedFd, guestFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        guest.start()
        retained.append(guest)
        #expect(host.acceptDuplicatedFd(acceptedFd, dupErrno: 0))
        await drainMainQueue()
    }

    /// Asserts `sink` forwards nothing — a descriptor handed to it is closed,
    /// which the peer of a socket pair sees as EOF.
    private func expectSinkCleared(_ sink: VsockDataConnectionSink) throws {
        let (a, b) = try makeRawSocketPair()
        defer { close(b) }  // `a` is owned — and must be closed — by the sink.
        sink.accept(fd: a)
        #expect(fcntl(b, F_SETFL, O_NONBLOCK) >= 0)
        var byte: UInt8 = 0
        #expect(recv(b, &byte, 1, 0) == 0)
    }

    // MARK: - Log port

    @Test("Enabling log forwarding live installs the log listener")
    func enablingLogInstallsItsListener() async {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        let installer = MockVsockListenerInstall()

        await instance.applyLiveLogPolicy(enabled: true, on: installer, sessionID: sessionID)

        #expect(installer.attached == [[KernovaVsockPort.log]])
        #expect(installer.detached.isEmpty)
    }

    @Test("Disabling log forwarding live withdraws the listener and stops the service")
    func disablingLogWithdrawsItsListener() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        try await connectGuest(
            to: instance.makeLogListenerHost(sessionID: sessionID), keptOpenBy: &guests)
        #expect(instance.vsockLogService != nil)

        let installer = MockVsockListenerInstall()
        await instance.applyLiveLogPolicy(enabled: false, on: installer, sessionID: sessionID)

        #expect(installer.detached == [[KernovaVsockPort.log]])
        #expect(installer.attached.isEmpty)
        #expect(instance.vsockLogService == nil)
    }

    // MARK: - Clipboard ports

    @Test("Enabling clipboard sharing live installs the channel and data ports in one hop")
    func enablingClipboardInstallsBothPorts() async {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        let installer = MockVsockListenerInstall()

        await instance.applyLiveClipboardPolicy(enabled: true, on: installer, sessionID: sessionID)

        #expect(
            installer.attached == [[KernovaVsockPort.clipboard, KernovaVsockPort.clipboardData]])
        #expect(installer.detached.isEmpty)
    }

    /// The data port must never outlive the channel port: a transfer admitted
    /// onto 49156 after the clipboard service is gone has nothing to serve it.
    @Test("Disabling clipboard sharing live withdraws the channel and data ports in one hop")
    func disablingClipboardWithdrawsBothPorts() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        try await connectGuest(
            to: instance.makeClipboardListenerHost(sessionID: sessionID), keptOpenBy: &guests)
        #expect(instance.clipboardService != nil)
        // A probe that would keep a forwarded descriptor open, so the EOF below
        // proves the sink was cleared rather than never set.
        instance.clipboardDataSink.set(RecordingAcceptor())

        let installer = MockVsockListenerInstall()
        await instance.applyLiveClipboardPolicy(enabled: false, on: installer, sessionID: sessionID)

        #expect(
            installer.detached == [[KernovaVsockPort.clipboard, KernovaVsockPort.clipboardData]])
        #expect(installer.attached.isEmpty)
        #expect(instance.clipboardService == nil)
        try expectSinkCleared(instance.clipboardDataSink)
    }
}
