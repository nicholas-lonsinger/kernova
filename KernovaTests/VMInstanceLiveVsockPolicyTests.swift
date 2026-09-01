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
@Suite("VMInstance live vsock policy", .admissionGated)
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
        // A feature listener exists only while its setting is on, and its
        // hand-off re-reads that setting — so a fixture standing in for a bound
        // feature port has to have them on.
        instance.configuration.clipboardSharingEnabled = true
        instance.configuration.agentLogForwardingEnabled = true
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        // The phase's session identity stands in for a live `VZVirtualMachine`,
        // not for the session context the services and their hand-offs live in.
        instance.beginSessionContext()
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

    // MARK: - Drop ports

    @Test("Enabling drag and drop live installs the channel and data ports in one hop")
    func enablingDropInstallsBothPorts() async {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        let installer = MockVsockListenerInstall()

        await instance.applyLiveDropPolicy(enabled: true, on: installer, sessionID: sessionID)

        #expect(installer.attached == [[KernovaVsockPort.drop, KernovaVsockPort.dropData]])
        #expect(installer.detached.isEmpty)
    }

    /// Same rule as the clipboard pair: an item connection admitted onto the
    /// data port after the drop service is gone has nothing to serve it.
    @Test("Disabling drag and drop live withdraws both ports and stops the service")
    func disablingDropWithdrawsBothPorts() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        try await connectGuest(
            to: instance.makeDropListenerHost(sessionID: sessionID), keptOpenBy: &guests)
        #expect(instance.vsockDropService != nil)
        instance.dropDataSink.set(RecordingAcceptor())

        let installer = MockVsockListenerInstall()
        await instance.applyLiveDropPolicy(enabled: false, on: installer, sessionID: sessionID)

        #expect(installer.detached == [[KernovaVsockPort.drop, KernovaVsockPort.dropData]])
        #expect(installer.attached.isEmpty)
        #expect(instance.vsockDropService == nil)
        try expectSinkCleared(instance.dropDataSink)
    }

    // MARK: - The channel dying under a service

    /// The keep-versus-nil half of the settle contract, pinned per service: the
    /// notification is uniform, the owner's reaction is not.
    @Test("A log channel dying under its service clears the instance's reference")
    func logChannelDeathClearsTheReference() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        try await connectGuest(
            to: instance.makeLogListenerHost(sessionID: sessionID), keptOpenBy: &guests)
        #expect(instance.vsockLogService != nil)

        // The guest agent quits mid-session. Nothing reads a settled log
        // service, so holding a dead channel until the next accept is pure
        // retention.
        guests.forEach { $0.close() }

        try await waitForChange { instance.vsockLogService == nil }
    }

    /// The clipboard is the opposite call: a settled service's materialized
    /// representations stay servable and the clipboard window reads its buffer
    /// through `ClipboardServicing`, so the reference outlives the channel.
    @Test("A clipboard channel dying under its service keeps the instance's reference")
    func clipboardChannelDeathKeepsTheReference() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        var guests: [VsockChannel] = []
        defer { guests.forEach { $0.close() } }
        try await connectGuest(
            to: instance.makeClipboardListenerHost(sessionID: sessionID), keptOpenBy: &guests)
        #expect(instance.clipboardService != nil)

        guests.forEach { $0.close() }

        try await waitForChange { instance.clipboardService?.isConnected == false }
        #expect(instance.clipboardService != nil)
    }

    // MARK: - Hand-offs crossing a toggle-off

    /// The accept runs on the VM's queue and only queues its hand-off, so a
    /// toggle-off can land on main in between — unbinding the port and stopping
    /// the service while this connection is still on its way to rebuild them.
    /// The hand-off has to refuse, or the feature the user switched off keeps
    /// running on the accepted channel for the rest of the session.
    @Test("A log hand-off queued before the toggle-off installs nothing")
    func logHandOffCrossingDisableIsRefused() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        let host = instance.makeLogListenerHost(sessionID: sessionID)
        let (acceptedFd, guestFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        guest.start()
        defer { guest.close() }

        // Admitted while forwarding is on, so the refusal under test is the
        // hand-off's own and not the admission gate's.
        #expect(host.acceptDuplicatedFd(acceptedFd, dupErrno: 0))
        // The user toggles the setting off before the queued hand-off gets its
        // turn on main.
        instance.configuration.agentLogForwardingEnabled = false

        await drainMainQueue()

        #expect(instance.vsockLogService == nil)
        await expectEOF(on: guest)
    }

    @Test("A drop hand-off queued before the toggle-off installs nothing")
    func dropHandOffCrossingDisableIsRefused() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        let host = instance.makeDropListenerHost(sessionID: sessionID)
        let (acceptedFd, guestFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        guest.start()
        defer { guest.close() }

        #expect(host.acceptDuplicatedFd(acceptedFd, dupErrno: 0))
        instance.dropDataSink.set(nil)
        instance.configuration.dropFilesEnabled = false

        await drainMainQueue()

        #expect(instance.vsockDropService == nil)
        try expectSinkCleared(instance.dropDataSink)
        await expectEOF(on: guest)
    }

    @Test("A clipboard hand-off queued before the toggle-off installs nothing")
    func clipboardHandOffCrossingDisableIsRefused() async throws {
        let (instance, sessionID) = makeInstanceWithLiveSession()
        let host = instance.makeClipboardListenerHost(sessionID: sessionID)
        let (acceptedFd, guestFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        guest.start()
        defer { guest.close() }

        #expect(host.acceptDuplicatedFd(acceptedFd, dupErrno: 0))
        // Cleared the way the disable branch clears it, so a hand-off that
        // repointed the sink at a rebuilt service would show up below.
        instance.clipboardDataSink.set(nil)
        instance.configuration.clipboardSharingEnabled = false

        await drainMainQueue()

        #expect(instance.clipboardService == nil)
        try expectSinkCleared(instance.clipboardDataSink)
        await expectEOF(on: guest)
    }
}
